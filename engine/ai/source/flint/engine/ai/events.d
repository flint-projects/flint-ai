/// Normalize terminal events and arena ownership across streaming providers.
module flint.engine.ai.events;

import flint.engine.ai.tool_calls : ArgumentBlock, ToolCalls;
import flint.engine.ai.types : ChatEvent, EventConsumer, EventKind, FailureKind;
import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status, Text;
import flint.serde : DecodeOptions, UnknownFields, decodeInto;
import flint.serde.json_visit : JsonMemberName, visitJsonObject;

@safe:

package(flint.engine.ai) Error protocolError(string message = "invalid provider streaming event") pure nothrow @nogc
{
    return Error(Status.invalidArgument, message);
}

package nothrow @nogc Error readFields(T)(scope const(ubyte)[] raw, ref T outValue, ref scope Arena arena)
{
    DecodeOptions options;
    options.unknownFields = UnknownFields.ignore;
    return decodeInto(raw, outValue, arena, options);
}

package(flint.engine.ai) size_t copyText(Text text, ref scope Arena arena, scope char[] output) nothrow @nogc
{
    const length = text.bytes.length;
    if (length == 0 || length > output.length)
        return 0;
    const status = arena.read(text.bytes, (scope const(ubyte)[] input) @safe nothrow @nogc {
        output[0 .. length] = cast(const(char)[]) input;
    });
    return status == Status.ok ? length : 0;
}

package(flint.engine.ai) Error readEventType(scope const(ubyte)[] json, ref scope Arena arena,
        scope char[] output, out size_t length) nothrow @nogc
{
    Text eventType;
    const parsed = visitJsonObject(json, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        return field.isName("type") ? decodeInto(value, eventType, arena) : Error.init;
    });
    if (parsed.code != Status.ok)
        return parsed;
    length = copyText(eventType, arena, output);
    return length == 0 ? protocolError("provider event type is missing or too long") : Error.init;
}

// dfmt off
package(flint.engine.ai) Error appendArguments(scope const(char)[] key, Text text,
        ref scope EventRun run, ref scope Arena arena) nothrow @nogc
{
    Error result;
    const visited = arena.read(text.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        result = run.calls.append(key, bytes);
    });
    return visited == Status.ok ? result : protocolError("provider tool event is missing an argument fragment");
}
// dfmt on

package Error finishArguments(scope const(char)[] key, Text text, ref scope EventRun run,
        ref scope Arena arena, scope EventConsumer consume, bool requireText = false) nothrow @nogc
{
    uint index;
    Result!Buffer result;
    if (text.bytes == Buffer.init && !requireText)
        result = run.calls.finish(key, null, arena, index);
    else
    {
        const viewed = arena.read(text.bytes, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            result = bytes.length != 0 ? run.calls.finish(key, bytes, arena, index) : Result!Buffer(Buffer.init,
                protocolError("provider tool event has empty final arguments"));
        });
        if (viewed != Status.ok)
            return protocolError("provider tool event is missing its final arguments");
    }
    return result.ok ? run.calls.publish(index, result.value, arena, consume) : result.error;
}

package(flint.engine.ai) size_t indexKey(uint index, ref scope char[10] target) pure nothrow @nogc
{
    size_t used = 1;
    for (uint rest = index; rest >= 10; rest /= 10)
        ++used;
    for (size_t pos = used; pos != 0; index /= 10)
        target[--pos] = cast(char)('0' + index % 10);
    return used;
}

package(flint.engine.ai) struct EventRun
{
@safe:
nothrow:
@nogc:

    ToolCalls calls;
    uint inputTokens;
    uint outputTokens;
    bool hasUsage;
    bool terminal;

    @disable this(this);
    @disable void opAssign(EventRun run);

    this(return scope ArgumentBlock[] blocks)
    {
        this.calls = ToolCalls(blocks);
    }

    Error text(Buffer content, ref scope Arena arena, scope EventConsumer consume) scope
    {
        if (terminal || content.length == 0)
            return Error.init;
        ChatEvent observed = ChatEvent(EventKind.textDelta, content);
        return consume(observed, arena);
    }

    void use(uint input, uint output) scope
    {
        if (!terminal)
        {
            inputTokens = input;
            outputTokens = output;
            hasUsage = true;
        }
    }

    Error success(ref scope Arena arena, scope EventConsumer consume) scope
    {
        if (terminal)
            return Error.init;
        if (!calls.completed)
            return fail(FailureKind.incomplete, Status.ioError,
                    "provider ended with incomplete tool arguments", arena, consume);
        terminal = true;
        if (hasUsage)
        {
            ChatEvent usage = ChatEvent(EventKind.usage, Buffer.init, null, inputTokens, outputTokens);
            const delivered = consume(usage, arena);
            if (delivered.code != Status.ok)
                return delivered;
        }
        ChatEvent complete = ChatEvent(EventKind.completed);
        return consume(complete, arena);
    }

    // dfmt off
    Error fail(FailureKind kind, Status failure, string description, ref scope Arena arena,
            scope EventConsumer consume) scope
    {
        if (terminal)
            return Error(failure, description);
        terminal = true;
        const text = arena.copyIn(cast(const(ubyte)[]) description);
        if (!text.ok)
            return text.error;
        ChatEvent failed = ChatEvent(EventKind.failed, text.value);
        failed.failure = kind;
        const delivered = consume(failed, arena);
        return delivered.code == Status.ok ? Error(failure, description) : delivered;
    }
    // dfmt on
}
