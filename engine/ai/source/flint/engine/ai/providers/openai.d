/// OpenAI Responses typed Server-Sent Events and function-call lifecycle.
module flint.engine.ai.providers.openai;

import flint.engine.ai.events : EventRun, appendArguments, finishArguments, copyText, protocolError,
    readEventType, readFields;
import flint.engine.ai.types : EventConsumer, FailureKind;
import flint.arena : Error, Arena = RequestArena, Status, Text;
import flint.serde : JsonRequired;
import flint.serde.json_visit : JsonMemberName, visitJsonObject;

@safe:

private struct TextDelta
{
    @JsonRequired Text delta;
}

private struct ToolDelta
{
    @JsonRequired Text item_id;
    @JsonRequired Text delta;
}

private struct ToolDone
{
    @JsonRequired Text item_id;
    @JsonRequired Text arguments;
}

private struct Item
{
    @JsonRequired Text type;
    Text id;
    Text call_id;
    Text name;
    Text arguments;
}

private struct ItemEvent
{
    @JsonRequired Item item;
}

private struct Usage
{
    @JsonRequired uint input_tokens;
    @JsonRequired uint output_tokens;
}

package(flint.engine.ai) Error responsesEvent(scope const(char)[] name, scope const(ubyte)[] json,
        ref scope EventRun run, ref scope Arena arena, scope EventConsumer consume) nothrow @nogc
{
    char[128] type;
    size_t size;
    const tagged = readEventType(json, arena, type[], size);
    if (tagged.code != Status.ok)
        return tagged;
    const kind = type[0 .. size];
    if (name != "message" && name != kind)
        return protocolError("Responses SSE name differs from its JSON type");
    if (kind == "response.completed")
    {
        const parsed = readUsage(json, run, arena);
        return parsed.code == Status.ok ? run.success(arena, consume) : parsed;
    }
    return responsePayload(kind, json, run, arena, consume);
}

private Error responsePayload(scope const(char)[] kind, scope const(ubyte)[] json, ref scope EventRun run,
        ref scope Arena arena, scope EventConsumer consume) nothrow @nogc
{
    switch (kind)
    {
    case "response.output_text.delta":
        TextDelta text;
        const parsed = readFields(json, text, arena);
        return parsed.code == Status.ok ? run.text(text.delta.bytes, arena, consume) : parsed;
    case "response.output_item.added", "response.output_item.done":
        return itemEvent(json, run,
                arena, consume, kind == "response.output_item.done");
    case "response.function_call_arguments.delta":
        return append(json, run, arena);
    case "response.function_call_arguments.done":
        return done(json, run, arena, consume);
    case "response.refusal.delta", "response.refusal.done":
        return run.fail(FailureKind.refused,
                Status.permissionDenied, "provider refused the request", arena, consume);
    case "response.incomplete":
        return run.fail(FailureKind.incomplete, Status.ioError, "provider reported incomplete output", arena, consume);
    case "response.failed", "error":
        return run.fail(FailureKind.provider, Status.unavailable,
                "provider returned a streaming error", arena, consume);
    default:
        // Responses can add lifecycle events. The checked discriminator keeps them out of known event paths.
        return Error.init;
    }
}

private Error itemEvent(scope const(ubyte)[] json, ref scope EventRun run, ref scope Arena arena,
        scope EventConsumer consume, bool finalItem) nothrow @nogc
{
    ItemEvent event;
    const parsed = readFields(json, event, arena);
    if (parsed.code != Status.ok)
        return parsed;
    char[64] type, name;
    char[128] key, id;
    const typeLength = copyText(event.item.type, arena, type[]);
    if (typeLength == 0)
        return protocolError();
    if (type[0 .. typeLength] != "function_call")
        return Error.init;
    const keyLength = copyText(event.item.id, arena, key[]);
    const nameLength = copyText(event.item.name, arena, name[]);
    const idLength = copyText(event.item.call_id, arena, id[]);
    const stored = run.calls.associate(key[0 .. keyLength], id[0 .. idLength], name[0 .. nameLength]);
    if (stored.code != Status.ok || !finalItem)
        return stored;
    return finishArguments(key[0 .. keyLength], event.item.arguments, run, arena, consume, true);
}

private Error append(scope const(ubyte)[] json, ref scope EventRun run, ref scope Arena arena) nothrow @nogc
{
    ToolDelta event;
    const parsed = readFields(json, event, arena);
    if (parsed.code != Status.ok)
        return parsed;
    char[128] key;
    const length = copyText(event.item_id, arena, key[]);
    return appendArguments(key[0 .. length], event.delta, run, arena);
}

// dfmt off
private Error done(scope const(ubyte)[] json, ref scope EventRun run, ref scope Arena arena,
        scope EventConsumer consume) nothrow @nogc
{
    ToolDone event;
    const parsed = readFields(json, event, arena);
    if (parsed.code != Status.ok)
        return parsed;
    char[128] key;
    const length = copyText(event.item_id, arena, key[]);
    return finishArguments(key[0 .. length], event.arguments, run, arena, consume, true);
}
// dfmt on

private Error readUsage(scope const(ubyte)[] json, ref scope EventRun run, ref scope Arena arena) nothrow @nogc
{
    bool responseFound;
    scope readResponse = (scope JsonMemberName member, scope const(ubyte)[] response) @safe nothrow @nogc {
        if (!member.isName("response"))
            return Error.init;
        responseFound = true;
        return visitJsonObject(response, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (!field.isName("usage") || value == cast(const(ubyte)[]) "null")
                return Error.init;
            Usage usage;
            const decoded = readFields(value, usage, arena);
            if (decoded.code == Status.ok)
                run.use(usage.input_tokens, usage.output_tokens);
            return decoded;
        });
    };
    const result = visitJsonObject(json, readResponse);
    return result.code != Status.ok || responseFound ? result
        : protocolError("Responses completion is missing a response");
}
