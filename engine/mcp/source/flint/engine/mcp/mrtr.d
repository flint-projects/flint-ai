/// Bounded application-mediated client input rounds.
module flint.engine.mcp.mrtr;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.mcp.jsonrpc : Range, append, inspect, isObject, isString, malformed, member,
    pack, quote, readString;
import flint.engine.mcp.types : McpElicitation;
import flint.serde.json_visit : JsonMemberName;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.engine.mcp):

private enum maxInputs = 16;

private struct Field
{
    char[128] name;
    size_t nameLength;
    Range request;
    Buffer response;
}

private struct InputMap
{
    Field[maxInputs] fields;
    size_t count;

    Error store(scope JsonMemberName key, size_t first, size_t length) scope nothrow @nogc
    {
        if (count == fields.length || key.length() == 0 || key.length() > fields[count].name.length)
            return Error(Status.resourceExhausted, "Too many or oversized MCP input requests");
        fields[count].nameLength = key.length();
        fields[count].request = Range(first, length);
        if (!key.copyName(cast(ubyte[]) fields[count].name[]))
            return malformed("Invalid MCP input request key");
        ++count;
        return Error.init;
    }
}

bool asksForInput(scope const(ubyte)[] result) nothrow @nogc
{
    const kind = member(result, "resultType");
    return kind.ok() && isString(kind.value.get(result), "input_required");
}

Result!Buffer prepareInput(scope const(ubyte)[] result, size_t maximum, scope McpElicitation handler,
        ref scope RequestArena work, ref scope RequestArena output, ref Context context) nothrow @nogc
{
    const requests = member(result, "inputRequests");
    const opaque = member(result, "requestState");
    if (!requests.ok() || !opaque.ok() || (!requests.value.present() && !opaque.value.present()))
        return Result!Buffer(Buffer.init, malformed("MCP input round lacks requests or state"));
    const state = opaque.value.get(result);
    const encodedRequests = requests.value.get(result);
    if (state.length && state[0] != '"')
        return Result!Buffer(Buffer.init, malformed("MCP requestState must be an opaque string"));
    InputMap collected;
    if (encodedRequests.length != 0)
    {
        const parsed = inspect(encodedRequests, &collected.store, maximum);
        if (parsed.code != Status.ok)
            return Result!Buffer(Buffer.init, parsed);
    }
    const accepted = validateRequests(collected, encodedRequests, handler !is null);
    if (accepted.code != Status.ok)
        return Result!Buffer(Buffer.init, accepted);
    const answered = answerRequests(collected, encodedRequests, handler, work, context);
    if (answered.code != Status.ok)
        return Result!Buffer(Buffer.init, answered);
    return pack(output, maximum, (ref scope JsonWriter writer) @safe nothrow @nogc {
        if (state.length)
        {
            append(writer, `,"requestState":`);
            writer.append(state);
        }
        if (encodedRequests.length)
            writeResponses(writer, collected, work);
    });
}

nothrow @nogc private Error validateRequests(scope const ref InputMap collected,
        scope const(ubyte)[] wire, bool hasHandler)
{
    // Validate every request before asking the application for input.
    foreach (ref field; collected.fields[0 .. collected.count])
    {
        const checked = checkRequest(field.request.get(wire));
        if (checked.code != Status.ok)
            return checked;
    }
    if (collected.count && !hasHandler)
        return Error(Status.unsupported, "MCP elicitation has no application handler");
    return Error.init;
}

private Error answerRequests(ref scope InputMap collected, scope const(ubyte)[] wire,
        scope McpElicitation handler, ref scope RequestArena work, ref Context context) nothrow @nogc
{
    foreach (ref field; collected.fields[0 .. collected.count])
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        const request = field.request.get(wire);
        const params = member(request, "params");
        const answered = handler(params.value.get(request), work, context);
        if (!answered.ok())
            return answered.error;
        bool accepted;
        const valid = work.read(answered.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            accepted = validResponse(bytes);
        });
        if (valid != Status.ok || !accepted)
            return malformed("invalid application MCP elicitation response");
        field.response = answered.value;
    }
    return Error.init;
}

nothrow @nogc private void writeResponses(ref scope JsonWriter writer, scope const ref InputMap collected,
        ref scope RequestArena work)
{
    append(writer, `,"inputResponses":{`);
    foreach (index, ref field; collected.fields[0 .. collected.count])
    {
        if (index)
            writer.put(',');
        quote(writer, field.name[0 .. field.nameLength]);
        writer.put(':');
        const read = work.read(field.response, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            writer.append(bytes);
        });
        if (read != Status.ok)
            writer.fail(read, "MCP elicitation result became stale");
    }
    writer.put('}');
}

private Error checkRequest(scope const(ubyte)[] request) nothrow @nogc
{
    const verb = member(request, "method");
    const params = member(request, "params");
    if (!verb.ok() || !params.ok() || !isObject(params.value.get(request)))
        return malformed("Invalid MCP input request");
    if (!isString(verb.value.get(request), "elicitation/create"))
        return Error(Status.unsupported, "MCP input request is outside declared capabilities");
    const wire = params.value.get(request);
    const mode = member(wire, "mode");
    const schema = member(wire, "requestedSchema");
    const message = member(wire, "message");
    if (mode.value.present() && !isString(mode.value.get(wire), "form"))
        return Error(Status.unsupported, "MCP elicitation mode is outside declared capabilities");
    char[1024] text;
    size_t length;
    if (!schema.ok() || !isObject(schema.value.get(wire)) || !message.ok()
            || !readString(message.value.get(wire), text[], length) || !length)
        return malformed("Invalid MCP elicitation parameters");
    return Error.init;
}

private bool validResponse(scope const(ubyte)[] response) nothrow @nogc
{
    const action = member(response, "action");
    const content = member(response, "content");
    if (!action.ok() || !content.ok())
        return false;
    const selected = action.value.get(response);
    if (isString(selected, "accept"))
        return isObject(content.value.get(response));
    return !content.value.present() && (isString(selected, "decline") || isString(selected, "cancel"));
}
