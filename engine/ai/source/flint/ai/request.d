/// Bounded provider-specific requests written into an exclusively leased upload.
module flint.ai.request;

import flint.ai.types : AiOptions, ChatMessage, ChatOptions, Provider, Role, RouterDialect, ToolDefinition;
import flint.arena : Buffer, Error, Arena = RequestArena, Result, Status;
import flint.serde.json_visit : JsonMemberName, visitJsonObject;
import flint.serde.json_write : JsonWriter, writeJsonDecimal;

@safe:

package(flint.ai) enum Wire : ubyte
{
    responses,
    messages,
    generateContent,
    routerResponses,
    routerChat
}

package(flint.ai) Wire wireFor(scope const ref AiOptions options) pure nothrow @nogc
{
    final switch (options.provider)
    {
    case Provider.openAI:
        return Wire.responses;
    case Provider.anthropic:
        return Wire.messages;
    case Provider.gemini:
        return Wire.generateContent;
    case Provider.openRouter:
        return options.routerDialect == RouterDialect.responses
            ? Wire.routerResponses : Wire.routerChat;
    }
}

package(flint.ai) Result!size_t encodeRequest(Wire wire, scope const(ChatMessage)[] messages,
        scope const ref ChatOptions options, ref scope Arena arena, scope ubyte[] output) nothrow @nogc
{
    const valid = checkOptions(wire, options, messages.length);
    if (valid.code != Status.ok)
        return Result!size_t(0, valid);

    scope writer = JsonWriter(output);
    size_t systems;
    if (wire == Wire.messages || wire == Wire.generateContent)
    {
        while (systems < messages.length && messages[systems].role == Role.system)
            ++systems;
        if (systems == messages.length)
            return Result!size_t(0, Error(Status.invalidArgument, "the provider requires a conversation message"));
    }

    beginRequest(writer, wire, options);
    if (systems != 0)
        writeSystems(writer, wire, messages[0 .. systems], arena);
    writeMessages(writer, wire, messages[systems .. $], arena);
    if (options.tools.length != 0)
    {
        if (options.toolRounds == options.maxToolRounds)
            limitTools(writer, wire);
        writeTools(writer, wire, options.tools, arena);
    }
    writer.put('}');
    return writer.error.code == Status.ok ? Result!size_t(writer.length) : Result!size_t(0,
            Error(writer.error.code, "provider request could not be encoded", writer.error.offset));
}

private Error checkOptions(Wire wire, scope const ref ChatOptions options, size_t messages) pure nothrow @nogc
{
    const ceiling = wire == Wire.messages ? 1 : 2;
    if (!options.model.length || options.model.length > 256 || !options.maxOutputTokens
            || !(options.temperature >= 0 && options.temperature <= ceiling))
        return Error(Status.invalidArgument, "invalid model, token budget or temperature");
    if (messages == 0 || messages > 128 || options.tools.length > 16
            || options.toolRounds > options.maxToolRounds || options.maxToolRounds > 8 || options
                .maxPrestreamRetries > 3)
        return Error(Status.resourceExhausted, "chat request exceeds its configured limits");
    return Error.init;
}

private void limitTools(ref scope JsonWriter writer, Wire wire) nothrow @nogc
{
    if (wire == Wire.generateContent)
        literal(writer, ",\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"NONE\"}}");
    else if (wire == Wire.messages)
        literal(writer, ",\"tool_choice\":{\"type\":\"none\"}");
    else
        literal(writer, ",\"tool_choice\":\"none\"");
}

private void beginRequest(ref scope JsonWriter writer, Wire wire, scope const ref ChatOptions options) nothrow @nogc
{
    if (wire == Wire.generateContent)
        literal(writer, "{\"generationConfig\":{\"candidateCount\":1,\"maxOutputTokens\":");
    else
    {
        literal(writer, "{\"stream\":true,\"model\":");
        quoted(writer, options.model);
        literal(writer, wire == Wire.responses || wire == Wire.routerResponses
                ? ",\"max_output_tokens\":" : ",\"max_tokens\":");
    }
    writer.unsignedNumber(options.maxOutputTokens);
    if (options.sendTemperature || options.temperature != 0)
    {
        literal(writer, ",\"temperature\":");
        writeJsonDecimal(writer, options.temperature);
    }
    if (wire == Wire.generateContent)
        writer.put('}');
    else if (wire == Wire.routerResponses || wire == Wire.routerChat)
        literal(writer, ",\"provider\":{\"require_parameters\":true}");
}

private void writeSystems(ref scope JsonWriter writer, Wire wire,
        scope const(ChatMessage)[] messages, ref scope Arena arena) nothrow @nogc
{
    literal(writer, wire == Wire.generateContent ? ",\"systemInstruction\":{\"parts\":[" : ",\"system\":[");
    foreach (index, ref message; messages)
    {
        if (message.toolCallId.length || message.toolName.length || message.providerState.length)
            writer.fail(Status.invalidArgument, "system messages cannot carry a tool call");
        if (index != 0)
            writer.put(',');
        literal(writer, wire == Wire.generateContent ? "{\"text\":" : "{\"type\":\"text\",\"text\":");
        text(writer, message.content, arena);
        writer.put('}');
    }
    writer.put(']');
    if (wire == Wire.generateContent)
        writer.put('}');
}

private void writeMessage(ref scope JsonWriter writer, Wire wire, scope const ref ChatMessage message,
        ref scope Arena arena) nothrow @nogc
{
    if (!checkedMessage(wire, message))
    {
        writer.fail(Status.invalidArgument, "invalid chat message or tool continuation");
        return;
    }
    const invocation = message.role == Role.assistant && message.toolName.length != 0;
    const result = message.role == Role.tool;
    if (invocation || result)
    {
        const hasIdentity = toolIdentity(wire, message);
        if (!hasIdentity || (result && message.providerState.length))
        {
            writer.fail(Status.invalidArgument, "tool continuation lacks provider identity");
            return;
        }
        writeCall(writer, wire, message, invocation, arena);
        return;
    }
    if (!plainMessage(wire, message))
    {
        writer.fail(Status.invalidArgument, "unexpected tool metadata or non-leading system message");
        return;
    }
    static immutable string[3] roles = ["system", "user", "assistant"];
    literal(writer, "{\"role\":");
    const role = wire == Wire.generateContent && message.role == Role.assistant ? "model" : roles[message.role];
    quoted(writer, role);
    literal(writer, wire == Wire.generateContent ? ",\"parts\":[{\"text\":" : ",\"content\":");
    text(writer, message.content, arena);
    literal(writer, wire == Wire.generateContent ? "}]}" : "}");
}

private bool plainMessage(Wire wire, scope const ref ChatMessage message) pure nothrow @nogc
{
    if (message.toolCallId.length || message.toolName.length || message.providerState.length)
        return false;
    return message.role != Role.system || (wire != Wire.messages && wire != Wire.generateContent);
}

private bool toolIdentity(Wire wire, scope const ref ChatMessage message) pure nothrow @nogc
{
    return wire == Wire.generateContent ? message.toolName.length != 0 : message.toolCallId.length != 0;
}

private bool checkedMessage(Wire wire, scope const ref ChatMessage message) pure nothrow @nogc
{
    if (message.role > Role.tool || message.toolCallId.length > 128 || message.toolName.length > 64
            || message.providerState.length > 65_536)
        return false;
    return wire == Wire.generateContent || message.providerState.length == 0;
}

private void writeMessages(ref scope JsonWriter writer, Wire wire,
        scope const(ChatMessage)[] messages, ref scope Arena arena) nothrow @nogc
{
    literal(writer, wire == Wire.generateContent ? ",\"contents\":[" : (wire == Wire.responses
            || wire == Wire.routerResponses ? ",\"input\":[" : ",\"messages\":["));
    foreach (index, ref message; messages)
    {
        if (index != 0)
            writer.put(',');
        writeMessage(writer, wire, message, arena);
    }
    writer.put(']');
}

private void writeCall(ref scope JsonWriter writer, Wire wire, scope const ref ChatMessage message,
        bool invocation, ref scope Arena arena) nothrow @nogc
{
    final switch (wire)
    {
    case Wire.responses, Wire.routerResponses:
        literal(writer, invocation
                ? "{\"type\":\"function_call\",\"call_id\":" : "{\"type\":\"function_call_output\",\"call_id\":");
        quoted(writer, message.toolCallId);
        if (invocation)
        {
            literal(writer, ",\"name\":");
            quoted(writer, message.toolName);
            literal(writer, ",\"arguments\":");
            jsonObject(writer, message.content, arena, true);
        }
        else
        {
            literal(writer, ",\"output\":");
            text(writer, message.content, arena);
        }
        writer.put('}');
        break;
    case Wire.messages:
        literal(writer, invocation
                ? "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":"
                : "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
        quoted(writer, message.toolCallId);
        if (invocation)
        {
            literal(writer, ",\"name\":");
            quoted(writer, message.toolName);
            literal(writer, ",\"input\":");
            jsonObject(writer, message.content, arena);
        }
        else
        {
            literal(writer, ",\"content\":");
            text(writer, message.content, arena);
        }
        literal(writer, "}]}");
        break;
    case Wire.generateContent:
        literal(writer, invocation
                ? "{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":"
                : "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":");
        quoted(writer, message.toolName);
        if (message.toolCallId.length)
        {
            literal(writer, ",\"id\":");
            quoted(writer, message.toolCallId);
        }
        if (invocation)
        {
            literal(writer, ",\"args\":");
            jsonObject(writer, message.content, arena);
        }
        else
        {
            literal(writer, ",\"response\":{\"output\":");
            text(writer, message.content, arena);
            writer.put('}');
        }
        writer.put('}');
        if (message.providerState.length)
        {
            literal(writer, ",\"thoughtSignature\":");
            quoted(writer, message.providerState);
        }
        literal(writer, "}]}");
        break;
    case Wire.routerChat:
        literal(writer, invocation
                ? "{\"role\":\"assistant\",\"tool_calls\":[{\"type\":\"function\",\"id\":"
                : "{\"role\":\"tool\",\"tool_call_id\":");
        quoted(writer, message.toolCallId);
        if (invocation)
        {
            literal(writer, ",\"function\":{\"name\":");
            quoted(writer, message.toolName);
            literal(writer, ",\"arguments\":");
            jsonObject(writer, message.content, arena, true);
            literal(writer, "}}]");
        }
        else
        {
            literal(writer, ",\"content\":");
            text(writer, message.content, arena);
        }
        writer.put('}');
        break;
    }
}

// dfmt off
private void writeTools(ref scope JsonWriter writer, Wire wire,
        scope const(ToolDefinition)[] tools, ref scope Arena arena) nothrow @nogc
{
    literal(writer, wire == Wire.generateContent ? ",\"tools\":[{\"functionDeclarations\":[" : ",\"tools\":[");
    foreach (index, ref entry; tools)
    {
        if (!toolName(entry.tool.name) || entry.tool.description.length > 4096)
        {
            writer.fail(Status.invalidArgument, "invalid advertised tool name or description");
            return;
        }
        foreach (ref prior; tools[0 .. index])
            if (prior.tool.name == entry.tool.name)
            {
                writer.fail(Status.conflict, "duplicate advertised tool name");
                return;
            }
        if (index != 0)
            writer.put(',');
        if (wire == Wire.routerChat)
            literal(writer, "{\"type\":\"function\",\"function\":{\"name\":");
        else if (wire == Wire.responses || wire == Wire.routerResponses)
            literal(writer, "{\"type\":\"function\",\"name\":");
        else
            literal(writer, "{\"name\":");
        quoted(writer, entry.tool.name);
        literal(writer, ",\"description\":");
        quoted(writer, entry.tool.description);
        literal(writer, wire == Wire.messages ? ",\"input_schema\":" : (wire == Wire.generateContent
                ? ",\"parametersJsonSchema\":" : ",\"parameters\":"));
        jsonObject(writer, entry.parameters, arena);
        writer.put('}');
        if (wire == Wire.routerChat)
            writer.put('}');
    }
    literal(writer, wire == Wire.generateContent ? "]}]" : "]");
}
// dfmt on

private bool toolName(scope const(char)[] value) pure nothrow @nogc
{
    if (!value.length || value.length > 64)
        return false;
    foreach (character; value)
        if (!(character >= 'a' && character <= 'z') && !(character >= 'A' && character <= 'Z')
                && !(character >= '0' && character <= '9') && character != '_' && character != '-')
            return false;
    return true;
}

private void literal(ref scope JsonWriter writer, scope const(char)[] value) nothrow @nogc
{
    writer.append(cast(const(ubyte)[]) value);
}

private void quoted(ref scope JsonWriter writer, scope const(char)[] value) nothrow @nogc
{
    writer.stringValue(cast(const(ubyte)[]) value);
}

private void text(ref scope JsonWriter writer, Buffer content, ref scope Arena arena) nothrow @nogc
{
    const status = arena.read(content, (scope const(ubyte)[] input) @safe nothrow @nogc {
        writer.stringValue(input);
    });
    if (status != Status.ok)
        writer.fail(status, "chat message storage is invalid");
}

// dfmt off
private void jsonObject(ref scope JsonWriter writer, Buffer input, ref scope Arena arena,
        bool quote = false) nothrow @nogc
{
    const status = arena.read(input, (scope const(ubyte)[] document) @safe nothrow @nogc {
        const parsed = visitJsonObject(document, (scope JsonMemberName, scope const(ubyte)[]) @safe nothrow @nogc {
            return Error.init;
        });
        if (parsed.code != Status.ok)
            writer.fail(parsed.code, "tool declaration or call arguments must be a valid JSON object");
        else if (quote)
            writer.stringValue(document);
        else
            writer.append(document);
    });
    if (status != Status.ok)
        writer.fail(status, "chat tool storage is invalid");
}
// dfmt on
