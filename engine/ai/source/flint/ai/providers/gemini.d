/// Gemini streamGenerateContent SSE. A finish reason must precede transport EOF.
module flint.ai.providers.gemini;

import flint.ai.events : EventRun, copyText, indexKey, protocolError, readFields;
import flint.ai.types : EventConsumer, FailureKind;
import flint.arena : Buffer, Error, Arena = RequestArena, Status, Text;
import flint.serde : JsonRequired;
import flint.serde.json_visit : JsonMemberName, visitJsonArray, visitJsonObject;

@safe:

private struct Usage
{
    uint promptTokenCount;
    uint candidatesTokenCount;
}

private struct Candidate
{
    uint index;
    Text finishReason;
}

private struct Content
{
    Text text;
    bool thought;
    Text thoughtSignature;
}

private struct Call
{
    Text id;
    @JsonRequired Text name;
    bool willContinue;
}

package(flint.ai) struct GeminiStream
{
    private uint calls;
    bool finished;

    Error event(scope const(char)[] name, scope const(ubyte)[] raw, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        if (name != "message")
            return protocolError("Gemini SSE requires the default event name");
        return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (field.isName("error"))
                return run.fail(FailureKind.provider, Status.unavailable,
                    "Gemini provider reported a stream error", arena, consume);
            if (field.isName("usageMetadata"))
            {
                Usage usage;
                const decoded = readFields(value, usage, arena);
                if (decoded.code == Status.ok)
                    run.use(usage.promptTokenCount, usage.candidatesTokenCount);
                return decoded;
            }
            if (field.isName("promptFeedback"))
                return feedback(value, run, arena, consume);
            if (!field.isName("candidates"))
                return Error.init;
            bool seen;
            return visitJsonArray(value, (scope const(ubyte)[] candidate) @safe nothrow @nogc {
                if (seen)
                    return protocolError("Gemini returned more than one candidate");
                seen = true;
                return readCandidate(candidate, run, arena, consume);
            });
        });
    }

    private Error readCandidate(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        Candidate candidate;
        const parsed = readFields(raw, candidate, arena);
        if (parsed.code != Status.ok)
            return parsed;
        if (candidate.index != 0)
            return protocolError("Gemini returned an unexpected candidate index");
        char[64] reason;
        const length = copyText(candidate.finishReason, arena, reason[]);
        const finish = reason[0 .. length];
        if (candidate.finishReason.bytes != Buffer.init && length == 0)
            return protocolError("Gemini stop reason is empty or too long");
        const accepted = checkStop(finish, run, arena, consume);
        if (accepted.code != Status.ok)
            return accepted;
        const delivered = visitJsonObject(raw, (scope JsonMemberName field,
                scope const(ubyte)[] value) @safe nothrow @nogc {
            return field.isName("content") ? readContent(value, run, arena, consume) : Error.init;
        });
        if (delivered.code == Status.ok && finish == "STOP")
            finished = true;
        return delivered;
    }

    private Error readContent(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        return visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (!field.isName("parts"))
                return Error.init;
            return visitJsonArray(value, (scope const(ubyte)[] part) @safe nothrow @nogc {
                return finished ? protocolError("Gemini sent content after its stop reason") : readPart(part,
                run, arena, consume);
            });
        });
    }

    private Error readPart(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
            scope EventConsumer consume) scope nothrow @nogc
    {
        Content content;
        const parsed = readFields(raw, content, arena);
        if (parsed.code != Status.ok || content.thought)
            return parsed;
        if (content.text.bytes != Buffer.init)
            return run.text(content.text.bytes, arena, consume);
        uint index;
        ResultArgument finalArgument;
        scope read = (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
            if (!field.isName("functionCall"))
                return Error.init;
            if (finalArgument.defined)
                return protocolError("Gemini repeated a function call field");
            const key = calls++;
            return readCall(value, key, run, arena, index, finalArgument);
        };
        const status = visitJsonObject(raw, read);
        if (status.code != Status.ok || !finalArgument.defined)
            return status;
        return run.calls.publish(index, finalArgument.data, arena, consume,
                content.thoughtSignature.bytes, finalArgument.assignedId);
    }
}

private Error checkStop(scope const(char)[] reason, ref scope EventRun run, ref scope Arena arena,
        scope EventConsumer consume) nothrow @nogc
{
    switch (reason)
    {
    case "", "STOP", "FINISH_REASON_UNSPECIFIED":
        return Error.init;
    case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
        return run.fail(FailureKind.refused,
                Status.permissionDenied, "Gemini blocked the response", arena, consume);
    default:
        return run.fail(FailureKind.incomplete, Status.ioError,
                "Gemini stopped before completing the response", arena, consume);
    }
}

private struct ResultArgument
{
    bool defined;
    Buffer data;
    bool assignedId;
}

private Error readCall(scope const(ubyte)[] raw, uint serial, ref scope EventRun run, ref scope Arena arena,
        out uint index, ref ResultArgument finalArgument) nothrow @nogc
{
    Call details;
    const decoded = readFields(raw, details, arena);
    if (decoded.code != Status.ok)
        return decoded;
    if (details.willContinue)
        return Error(Status.unsupported, "Gemini partial function arguments require explicit protocol support");
    char[10] digits;
    const digitCount = indexKey(serial, digits);
    char[128] id;
    char[64] tool;
    size_t length = copyText(details.id, arena, id[]);
    if (details.id.bytes == Buffer.init)
    {
        id[0 .. 6] = "flint-";
        id[6 .. 6 + digitCount] = digits[0 .. digitCount];
        length = 6 + digitCount;
    }
    const toolSize = copyText(details.name, arena, tool[]);
    const stored = run.calls.associate(digits[0 .. digitCount], id[0 .. length], tool[0 .. toolSize]);
    if (stored.code != Status.ok)
        return stored;
    bool seen;
    const parsed = visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (field.isName("partialArgs"))
            return Error(Status.unsupported, "Gemini partial function arguments require explicit protocol support");
        if (!field.isName("args"))
            return Error.init;
        if (seen)
            return protocolError("Gemini repeated a function argument field");
        seen = true;
        const completed = run.calls.finish(digits[0 .. digitCount], value, arena, index);
        finalArgument = ResultArgument(completed.ok, completed.value, details.id.bytes != Buffer.init);
        return completed.error;
    });
    if (parsed.code != Status.ok || seen)
        return parsed;
    const empty = run.calls.finish(digits[0 .. digitCount], null, arena, index);
    finalArgument = ResultArgument(empty.ok, empty.value, details.id.bytes != Buffer.init);
    return empty.error;
}

private Error feedback(scope const(ubyte)[] raw, ref scope EventRun run, ref scope Arena arena,
        scope EventConsumer consume) nothrow @nogc
{
    bool blocked;
    const parsed = visitJsonObject(raw, (scope JsonMemberName field, scope const(ubyte)[] value) @safe nothrow @nogc {
        if (field.isName("blockReason"))
            blocked = value != cast(const(ubyte)[]) "\"BLOCK_REASON_UNSPECIFIED\"";
        return Error.init;
    });
    if (parsed.code != Status.ok || !blocked)
        return parsed;
    return run.fail(FailureKind.refused, Status.permissionDenied, "Gemini blocked the prompt", arena, consume);
}
