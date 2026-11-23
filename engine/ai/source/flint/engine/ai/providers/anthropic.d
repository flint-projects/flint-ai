/// Anthropic Messages SSE. Tool arguments complete at content_block_stop.
module flint.engine.ai.providers.anthropic;

import flint.engine.ai.events : EventRun, appendArguments, copyText, finishArguments, indexKey,
    protocolError, readEventType, readFields;
import flint.engine.ai.types : EventConsumer, FailureKind;
import flint.arena : Buffer, Error, Arena = RequestArena, Status, Text;
import flint.serde : JsonRequired;
import flint.serde.json_visit : JsonMemberName, visitJsonObject;

@safe:

private enum Block : ubyte
{
    empty,
    text,
    tool,
    ignored,
    closed
}

private enum Stop : ubyte
{
    pending,
    complete,
    incomplete,
    refused
}

private struct Indexed
{
    @JsonRequired uint index;
}

private struct Usage
{
    uint input_tokens = uint.max;
    uint output_tokens = uint.max;
}

private struct BlockDelta
{
    @JsonRequired Text type;
    Text text;
    Text partial_json;
}

private struct DeltaEvent
{
    @JsonRequired uint index;
    @JsonRequired BlockDelta delta;
}

private struct BlockStart
{
    @JsonRequired Text type;
    Text id;
    Text name;
    Text text;
}

package(flint.engine.ai) struct AnthropicStream
{
    private Block[128] blocks;
    private Stop stop;
    private bool started;

    Error event(scope const(char)[] name, scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        char[64] type;
        size_t length;
        const validated = readEventType(raw, arena, type[], length);
        if (validated.code != Status.ok)
            return validated;
        const kind = type[0 .. length];
        if (name != "message" && name != kind)
            return protocolError("Messages SSE name differs from its JSON type");
        if (kind == "error")
            return run.fail(FailureKind.provider, Status.unavailable,
                    "Messages provider reported a stream error", arena, consume);
        if (kind == "message_start")
            return start(raw, run, arena);
        return dispatch(kind, raw, run, arena, consume);
    }

    private Error start(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena) scope nothrow @nogc
    {
        if (started)
            return protocolError("Messages repeated its start event");
        started = true;
        bool found;
        scope read = (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (!field.isName("message"))
                return Error.init;
            found = true;
            return readUsage(value, run, arena);
        };
        const result = visitJsonObject(raw, read);
        return result.code != Status.ok || found ? result : protocolError("Messages start omitted its message");
    }

    private Error dispatch(scope const(char)[] kind, scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        switch (kind)
        {
        case "message_delta":
            return started ? messageDelta(raw, run, arena) : protocolError("Messages delta preceded its start event");
        case "message_stop":
            return started ? complete(run, arena, consume) : protocolError("Messages stop preceded its start event");
        case "content_block_start",
                "content_block_stop":
                if (!started) return protocolError("Messages content preceded its start event");
            return boundary(kind == "content_block_start", raw, run, arena, consume);
        case "content_block_delta":
            return started ? delta(raw, run, arena, consume) : protocolError(
                    "Messages content preceded its start event");
        default:
            return Error.init;
        }
    }

    private Error boundary(bool begin, scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        Indexed indexed;
        const decoded = readFields(raw, indexed, arena);
        if (decoded.code != Status.ok)
            return decoded;
        if (indexed.index >= blocks.length)
            return Error(Status.resourceExhausted, "Messages content block index exceeds its limit");
        ref block = blocks[indexed.index];
        if (begin ? block != Block.empty : block == Block.empty || block == Block.closed)
            return protocolError("Messages content block is out of order");

        char[10] index;
        const size = indexKey(indexed.index, index);
        const key = index[0 .. size];
        if (!begin)
        {
            const deliver = block == Block.tool;
            block = Block.closed;
            return deliver ? finishArguments(key, Text.init, run, arena, consume) : Error.init;
        }

        scope read = (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            return field.isName("content_block") ? openBlock(value, key, block, run, arena, consume) : Error.init;
        };
        const status = visitJsonObject(raw, read);
        return status.code != Status.ok || block != Block.empty ? status
            : protocolError("Messages content block is missing");
    }

    private Error delta(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        DeltaEvent record;
        const parsed = readFields(raw, record, arena);
        if (parsed.code != Status.ok)
            return parsed;
        if (record.index >= blocks.length)
            return Error(Status.resourceExhausted, "Messages content block index exceeds its limit");
        const block = blocks[record.index];
        if (block == Block.empty || block == Block.closed)
            return protocolError("Messages content delta is out of order");
        char[64] discriminator;
        const length = copyText(record.delta.type, arena, discriminator[]);
        switch (discriminator[0 .. length])
        {
        case "":
            return protocolError();
        case "text_delta":
            if (block != Block.text || record.delta.text.bytes == Buffer.init)
                return protocolError();
            return run.text(record.delta.text.bytes, arena, consume);
        case "input_json_delta":
            if (block != Block.tool)
                return protocolError();
            char[10] index;
            const size = indexKey(record.index, index);
            return appendArguments(index[0 .. size], record.delta.partial_json, run, arena);
        default:
            // Anthropic documents new unknown event and block variants as forward-compatible.
            return Error.init;
        }
    }

    // dfmt off
    private Error messageDelta(scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena) scope nothrow @nogc
    {
        const parsed = readUsage(raw, run, arena);
        if (parsed.code != Status.ok)
            return parsed;
        return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (!field.isName("delta"))
                return Error.init;
            scope decode = (scope JsonMemberName member, scope const(ubyte)[] reason) @safe nothrow @nogc {
                if (!member.isName("stop_reason") || reason == cast(const(ubyte)[]) "null")
                    return Error.init;
                Text text;
                auto decoded = readFields(reason, text, arena);
                if (decoded.code == Status.ok)
                    stop = classify(text, arena);
                return decoded;
            };
            return visitJsonObject(value, decode);
        });
    }
    // dfmt on

    private Error complete(ref scope EventRun run, ref scope Arena arena, scope EventConsumer send) scope nothrow @nogc
    {
        foreach (block; blocks)
            if (block != Block.empty && block != Block.closed)
                return run.fail(FailureKind.incomplete, Status.ioError,
                        "Messages ended with an open content block", arena, send);
        if (stop == Stop.refused)
            return run.fail(FailureKind.refused, Status.permissionDenied, "Messages provider refused", arena, send);
        if (stop != Stop.complete)
            return run.fail(FailureKind.incomplete, Status.ioError, "Messages response was incomplete", arena, send);
        return run.success(arena, send);
    }
}

private Error openBlock(scope const(ubyte)[] raw, scope const(char)[] key, ref Block block,
        ref scope EventRun run, ref scope Arena arena, scope EventConsumer consume) nothrow @nogc
{
    BlockStart start;
    const parsed = readFields(raw, start, arena);
    if (parsed.code != Status.ok)
        return parsed;
    char[64] category;
    const length = copyText(start.type, arena, category[]);
    switch (category[0 .. length])
    {
    case "":
        return protocolError();
    case "text":
        if (start.text.bytes == Buffer.init)
            return protocolError();
        block = Block.text;
        return run.text(start.text.bytes, arena, consume);
    case "tool_use":
        block = Block.tool;
        return openCall(raw, key, start, run, arena);
    default:
        block = Block.ignored;
        return Error.init;
    }
}

private Error openCall(scope const(ubyte)[] raw, scope const(char)[] key, scope const ref BlockStart start,
        ref scope EventRun run, ref scope Arena arena) nothrow @nogc
{
    char[128] id;
    char[64] tool;
    const idSize = copyText(start.id, arena, id[]);
    const toolSize = copyText(start.name, arena, tool[]);
    const added = run.calls.associate(key, id[0 .. idSize], tool[0 .. toolSize]);
    if (added.code != Status.ok)
        return added;
    return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (!field.isName("input"))
            return Error.init;
        bool hasFields;
        const checked = visitJsonObject(value, (scope JsonMemberName, scope const(ubyte)[]) @safe nothrow @nogc {
            hasFields = true;
            return Error.init;
        });
        return checked.code != Status.ok || !hasFields ? checked : run.calls.append(key, value);
    });
}

private Error readUsage(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena) nothrow @nogc
{
    return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (!field.isName("usage"))
            return Error.init;
        Usage latest;
        const decoded = readFields(value, latest, arena);
        if (decoded.code == Status.ok && (latest.input_tokens != uint.max || latest.output_tokens != uint.max))
            run.use(latest.input_tokens == uint.max ? run.inputTokens : latest.input_tokens,
                latest.output_tokens == uint.max ? run.outputTokens : latest.output_tokens);
        return decoded;
    });
}

private Stop classify(Text text, ref scope Arena arena) nothrow @nogc
{
    if (text.bytes == Buffer.init)
        return Stop.pending;
    char[64] reason;
    const size = copyText(text, arena, reason[]);
    switch (reason[0 .. size])
    {
    case "end_turn", "stop_sequence", "tool_use":
        return Stop.complete;
    case "refusal":
        return Stop.refused;
    default:
        return Stop.incomplete;
    }
}
