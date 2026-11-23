/// OpenRouter exposes distinct Responses and Chat Completions stream protocols.
module flint.engine.ai.providers.openrouter;

import flint.engine.ai.events : EventRun, appendArguments, copyText, finishArguments, indexKey,
    protocolError, readFields;
import flint.engine.ai.providers.openai : responsesEvent;
import flint.engine.ai.types : EventConsumer, FailureKind;
import flint.arena : Buffer, Error, Arena = RequestArena, Status, Text;
import flint.serde : JsonName, JsonRequired;
import flint.serde.json_visit : JsonMemberName, visitJsonArray, visitJsonObject;

@safe:

package(flint.engine.ai) Error routerResponsesEvent(scope const(char)[] name, scope const(ubyte)[] raw,
        ref scope EventRun run, ref scope Arena arena, scope EventConsumer consume) nothrow @nogc
{
    if (raw == cast(const(ubyte)[]) "[DONE]")
        return run.terminal ? Error.init : run.fail(FailureKind.incomplete, Status.ioError,
                "OpenRouter ended before a terminal event", arena, consume);
    bool failed;
    const checked = visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (field.isName("error"))
            failed = value != cast(const(ubyte)[]) "null";
        return Error.init;
    });
    if (checked.code != Status.ok)
        return checked;
    if (failed)
        return run.fail(FailureKind.provider, Status.unavailable,
                "OpenRouter reported a provider error", arena, consume);
    // This endpoint specifies OpenAI's Responses event envelopes for normal output.
    return responsesEvent(name, raw, run, arena, consume);
}

private enum Finish : ubyte
{
    pending,
    stop,
    tools
}

private struct Usage
{
    @JsonRequired
    uint prompt_tokens;
    @JsonRequired
    uint completion_tokens;
}

private struct Choice
{
    @JsonRequired
    uint index;
}

private struct FunctionDelta
{
    Text name;
    Text arguments;
}

private struct ToolDelta
{
    @JsonRequired
    uint index;
    Text id;
    @JsonRequired
    @JsonName("function")
    FunctionDelta functionPart;
}

package(flint.engine.ai) struct RouterChatStream
{
    private bool[16] activeCalls;
    private Finish finish;

    Error event(scope const(char)[] name, scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        if (name != "message")
            return protocolError("OpenRouter Chat Completions requires the default event name");
        if (raw == cast(const(ubyte)[]) "[DONE]")
            return finish == Finish.pending ? run.fail(FailureKind.incomplete, Status.ioError,
                    "OpenRouter ended without a finish reason", arena, consume) : run.success(arena, consume);
        const error = checkTopError(raw, run, arena, consume);
        if (error.code != Status.ok)
            return error;
        return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (field.isName("usage") && value != cast(const(ubyte)[]) "null")
            {
                Usage accounting;
                auto parsed = readFields(value, accounting, arena);
                if (parsed.code == Status.ok)
                    run.use(accounting.prompt_tokens, accounting.completion_tokens);
                return parsed;
            }
            if (!field.isName("choices"))
                return Error.init;
            return visitJsonArray(value, (scope const(ubyte)[] choice) @safe nothrow @nogc {
                return readChoice(choice, run, arena, consume);
            });
        });
    }

    private Error readChoice(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        Choice choice;
        const decoded = readFields(raw, choice, arena);
        if (decoded.code != Status.ok)
            return decoded;
        if (choice.index != 0)
            return protocolError("OpenRouter returned an unexpected choice index");
        char[64] reason;
        size_t reasonSize;
        const tagged = findReason(raw, arena, reason[], reasonSize);
        if (tagged.code != Status.ok)
            return tagged;
        scope read = (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            return field.isName("delta") ? readDelta(value, run, arena, consume) : Error.init;
        };
        const observed = visitJsonObject(raw, read);
        if (observed.code != Status.ok || reasonSize == 0)
            return observed;
        return recordFinish(reason[0 .. reasonSize], run, arena, consume);
    }

    private Error recordFinish(scope const(char)[] value, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        if (value == "content_filter")
            return run.fail(FailureKind.refused, Status.permissionDenied,
                    "OpenRouter filtered the response", arena, consume);
        if (value == "length")
            return run.fail(FailureKind.incomplete, Status.ioError,
                    "OpenRouter reached the output limit", arena, consume);
        if (value == "error")
            return run.fail(FailureKind.provider, Status.unavailable,
                    "OpenRouter reported a provider error", arena, consume);
        if (value != "stop" && value != "tool_calls")
            return protocolError("OpenRouter returned an unsupported finish reason");
        const next = value == "stop" ? Finish.stop : Finish.tools;
        if (finish != Finish.pending)
            return next == finish ? Error.init : protocolError("OpenRouter changed the finish reason");
        finish = next;
        return next == Finish.stop ? Error.init : deliverToolCalls(run, arena, consume);
    }

    // dfmt off
    private Error deliverToolCalls(ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        bool found;
        foreach (index, active; activeCalls[])
        {
            if (!active)
                continue;
            found = true;
            char[10] key;
            const size = indexKey(cast(uint) index, key);
            const delivered = finishArguments(key[0 .. size], Text.init, run, arena, consume);
            if (delivered.code != Status.ok)
                return delivered;
        }
        return found ? Error.init : protocolError("OpenRouter ended a tool-free choice with tool_calls");
    }
    // dfmt on

    private Error readDelta(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (field.isName("content") || field.isName("refusal"))
                return readText(value, field.isName("refusal"), run, arena, consume);
            if (!field.isName("tool_calls"))
                return Error.init;
            if (finish != Finish.pending)
                return protocolError("OpenRouter sent tool arguments after the finish reason");
            return visitJsonArray(value, (scope const(ubyte)[] tool) @safe nothrow @nogc {
                return readTool(tool, run, arena);
            });
        });
    }

    private Error readText(scope const(ubyte)[] wireText, bool refusal, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        if (wireText == cast(const(ubyte)[]) "null")
            return Error.init;
        Text text;
        const parsed = readFields(wireText, text, arena);
        if (parsed.code != Status.ok || text.bytes.length == 0)
            return parsed;
        if (refusal)
            return run.fail(FailureKind.refused, Status.permissionDenied,
                    "OpenRouter provider refused", arena, consume);
        if (finish != Finish.pending)
            return protocolError("OpenRouter sent text after the finish reason");
        return run.text(text.bytes, arena, consume);
    }

    private Error readTool(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena) scope nothrow @nogc
    {
        ToolDelta tool;
        const parsed = readFields(raw, tool, arena);
        if (parsed.code != Status.ok)
            return parsed;
        if (tool.index >= activeCalls.length)
            return Error(Status.resourceExhausted, "OpenRouter tool index exceeds its limit");
        char[10] digits;
        const digitCount = indexKey(tool.index, digits);
        const key = digits[0 .. digitCount];
        if (tool.id.bytes != Buffer.init || tool.functionPart.name.bytes != Buffer.init)
        {
            char[128] id;
            char[64] name;
            const idLength = copyText(tool.id, arena, id[]);
            const nameLength = copyText(tool.functionPart.name, arena, name[]);
            const added = run.calls.associate(key, id[0 .. idLength], name[0 .. nameLength]);
            if (added.code != Status.ok)
                return added;
            activeCalls[tool.index] = true;
        }
        if (!activeCalls[tool.index])
            return protocolError("OpenRouter sent arguments before identifying the tool");
        return tool.functionPart.arguments.bytes == Buffer.init ? Error.init : appendArguments(key,
                tool.functionPart.arguments, run, arena);
    }
}

// dfmt off
private Error findReason(scope const(ubyte)[] raw, ref scope Arena arena, scope char[] output,
        out size_t size) nothrow @nogc
{
    return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (!field.isName("finish_reason") || value == cast(const(ubyte)[]) "null")
            return Error.init;
        Text text;
        auto parsed = readFields(value, text, arena);
        if (parsed.code == Status.ok)
        {
            size = copyText(text, arena, output);
            if (size == 0)
                return protocolError("OpenRouter finish reason is empty or too long");
        }
        return parsed;
    });
}
// dfmt on

private Error checkTopError(scope const(ubyte)[] json, ref scope EventRun run, ref scope Arena arena,
        scope EventConsumer consume) nothrow @nogc
{
    return visitJsonObject(json, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (!field.isName("error") || value == cast(const(ubyte)[]) "null")
            return Error.init;
        return run.fail(FailureKind.provider, Status.unavailable,
            "OpenRouter reported a provider error", arena, consume);
    });
}
