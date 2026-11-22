/// Shared registry dispatch, with distinct modern and legacy admission.
module flint.mcp.protocol;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.mcp.header_values : matchesHeader;
import flint.mcp.jsonrpc : Emit, Envelope, Identity, Range, append, decodeEnvelope, headerMismatch,
    inspect, internalError, invalidParameters, invalidRequest, isObject, malformed, maxMessage,
    maxResource, methodNotFound, pack, parseError, quote, readString, unsupportedVersion, writeId;
import flint.mcp.legacy : LegacyPhase, LegacySession, SessionKey, legacyRevision, validateInitialize;
import flint.mcp.modern : Metadata, endModernResult, metadata, modernRevision, writeInfo;
import flint.mcp.internal.registry : BeginTool, Registry;
import flint.mcp.types : McpOptions, ProtocolRevision, ToolResult;
import flint.serde : DecodeOptions;
import flint.serde.json_visit : JsonMemberName, visitJsonArray;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.mcp):

struct Headers
{
    bool http;
    bool invalid;
    const(char)[] release;
    const(char)[] method;
    const(char)[] name;
    const(char)[] session;
    bool terminate;
}

struct Reply
{
    ushort status = 200;
    Buffer body;
    SessionKey session;
    bool mintSession;
    Error error;
}

private struct Call
{
    Envelope data;
    bool modern;
}

/// Every params member the dispatcher reads, located by one scan of the params object.
private struct ParamFields
{
    Range metaMember;
    Range name;
    Range uri;
    Range arguments;
    Range cursor;
    bool valid;
    /// Decoded `_meta` protocol fields.
    Metadata meta;

    void scan(scope const(ubyte)[] params) scope nothrow @nogc
    {
        valid = inspect(params, &field).code == Status.ok;
        meta = metadata(valid ? metaMember.get(params) : null);
    }

    private Error field(scope JsonMemberName key, size_t offset, size_t length) scope nothrow @nogc
    {
        const span = Range(offset, length);
        if (key.isName("_meta"))
            metaMember = span;
        else if (key.isName("name"))
            name = span;
        else if (key.isName("uri"))
            uri = span;
        else if (key.isName("arguments"))
            arguments = span;
        else if (key.isName("cursor"))
            cursor = span;
        return Error.init;
    }
}

final class Protocol
{
    Registry registry;
    private McpOptions limits;
    private LegacySession[64] sessions;
    private LegacyPhase stdioPhase;

    this(McpOptions options)
    {
        limits = options;
    }

    private bool supportsModern() const scope pure nothrow @nogc
    {
        return limits.revision == ProtocolRevision.modern20260728;
    }

    private bool supportsLegacy() const scope pure nothrow @nogc
    {
        return limits.revision == ProtocolRevision.legacy20251125 || limits.acceptLegacy;
    }

    ushort terminate(scope const(char)[] session) scope nothrow @nogc
    {
        if (!supportsLegacy() || session.length == 0)
            return 405;
        foreach (ref item; sessions[0 .. limits.maxInFlight])
        {
            if (item.recognizes(session))
            {
                item = LegacySession.init;
                return 204;
            }
        }
        return 404;
    }

    Reply dispatch(scope const(ubyte)[] message, scope const ref Headers headers,
            ref scope RequestArena work, ref scope RequestArena output, ref Context context,
            scope BeginTool admitted = null) scope nothrow @nogc
    {
        const parsed = decodeEnvelope(message, limits.maxMessageBytes);
        return dispatchEnvelope(parsed, message, headers, work, output, context, admitted);
    }

    /// Dispatch a message whose envelope the transport already decoded with this server's byte limit.
    Reply dispatchEnvelope(scope const ref Result!Envelope parsed, scope const(ubyte)[] message,
            scope const ref Headers headers, ref scope RequestArena work, ref scope RequestArena output,
            ref Context context, scope BeginTool admitted = null) scope nothrow @nogc
    {
        if (!parsed.ok())
        {
            const fault = parsed.error.offset == size_t.max ? invalidRequest : parseError;
            return fail(output, Identity.init, 400, fault, "Invalid JSON-RPC request");
        }
        const data = parsed.value;
        if (data.methodLength == 0)
            return fail(output, Identity.init, 400, invalidRequest, "Expected a JSON-RPC request");
        const params = data.params.get(message);
        ParamFields fields;
        fields.scan(params);
        const verb = data.verb();

        if (modernOpening(fields.meta, headers, verb))
            return modern(data, params, fields, headers, work, output, context, admitted);
        if (supportsLegacy() && legacyOpening(headers, verb))
            return legacy(data, params, fields, headers, work, output, context, admitted);
        if (!supportsModern())
            return fail(output, data.id, 400, invalidRequest, "Legacy initialize is required");
        return modern(data, params, fields, headers, work, output, context, admitted);
    }

    private bool legacyOpening(scope const ref Headers headers, scope const(char)[] verb) const scope pure nothrow @nogc
    {
        return verb == "initialize" || headers.session.length != 0 || (!headers.http
                && stdioPhase != LegacyPhase.initial);
    }

    nothrow @nogc private Reply modern(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref ParamFields fields, scope const ref Headers headers, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope
    {
        if (!supportsModern())
            return fail(output, data.id, 400, methodNotFound, "Legacy initialize is required");
        scope const meta = &fields.meta;
        if (headers.invalid || (headers.http && headerConflicts(data, *meta, headers)))
            return fail(output, data.id, 400, headerMismatch, "MCP headers do not match the request");
        if (!meta.valid)
            return fail(output, data.id, 400, invalidParameters, "Missing or invalid MCP client metadata");
        if (meta.revision() != modernRevision)
            return versionFault(output, data.id, meta.revision());

        if (headers.http && !matchingName(data.verb(), params, fields, headers.name))
            return fail(output, data.id, 400, headerMismatch, "Mcp-Name does not match the request");
        if (!data.id.present)
            return fail(output, Identity.init, 400, invalidRequest, "Modern MCP requires a request ID");
        return accept(Call(data, true), params, fields, work, output, context, admitted);
    }

    nothrow @nogc private Reply legacy(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref ParamFields fields, scope const ref Headers headers, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope
    {
        if (headers.invalid)
            return fail(output, data.id, 400, invalidRequest, "Invalid legacy HTTP headers");
        if (data.verb() == "initialize")
            return initialize(data, params, headers, output);
        if (!headers.http)
            return legacyPhase(data, params, fields, stdioPhase, work, output, context, admitted);
        if (headers.release.length != 0 && headers.release != legacyRevision)
            return fail(output, data.id, 400, invalidRequest, "Invalid legacy HTTP protocol version");
        if (headers.session.length == 0)
            return fail(output, data.id, 400, invalidRequest, "Mcp-Session-Id is required");
        foreach (ref session; sessions[0 .. limits.maxInFlight])
        {
            if (session.recognizes(headers.session))
                return legacyPhase(data, params, fields, session.phase, work, output, context, admitted);
        }
        return fail(output, data.id, 404, invalidRequest, "Unknown legacy MCP session");
    }

    nothrow @nogc private Reply legacyPhase(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref ParamFields fields, ref LegacyPhase phase, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope
    {
        if (data.verb() == "notifications/initialized" && !data.id.present && phase == LegacyPhase.awaitingInitialized)
        {
            phase = LegacyPhase.ready;
            return Reply(202);
        }
        if (phase != LegacyPhase.ready)
            return fail(output, data.id, 400, invalidRequest, "Legacy initialization is incomplete");
        if (!data.id.present)
            return Reply(202);
        return accept(Call(data, false), params, fields, work, output, context, admitted);
    }

    private Reply initialize(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref Headers headers, ref scope RequestArena output) scope nothrow @nogc
    {
        if (!data.id.present || validateInitialize(params).code != Status.ok
                || headers.session.length || (!headers.http && stdioPhase != LegacyPhase.initial))
            return fail(output, data.id, 400, invalidParameters, "Invalid legacy initialize");
        if (!headers.http)
        {
            auto response = discovery(output, Call(data, false));
            if (response.error.code == Status.ok)
                stdioPhase = LegacyPhase.awaitingInitialized;
            return response;
        }
        foreach (ref session; sessions[0 .. limits.maxInFlight])
        {
            if (session.phase != LegacyPhase.initial)
                continue;
            const generated = session.key.generate();
            if (generated.code != Status.ok)
                return fail(output, data.id, 503, internalError, "MCP session admission failed");
            auto response = discovery(output, Call(data, false));
            if (response.error.code == Status.ok)
            {
                session.phase = LegacyPhase.awaitingInitialized;
                response.mintSession = true;
                response.session = session.key;
            }
            return response;
        }
        return fail(output, data.id, 503, internalError, "MCP session capacity reached");
    }

    nothrow @nogc private Reply accept(const Call call, scope const(ubyte)[] params,
            scope const ref ParamFields fields, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope
    {
        switch (call.data.verb())
        {
        case "ping":
            return complete(output, call, null);
        case "server/discover":
            if (call.modern)
                return discovery(output, call);
            break;
        case "tools/list":
            return list(output, call, params, fields, true);
        case "resources/list":
            return list(output, call, params, fields, false);
        case "tools/call":
            return invoke(work, output, call, params, fields, context, admitted);
        case "resources/read":
            return readResource(work, output, call, params, fields, context);
        default:
            break;
        }
        return fail(output, call.data.id, 404, methodNotFound, "Unknown MCP method");
    }

    private Reply discovery(ref scope RequestArena output, const Call call) scope nothrow @nogc
    {
        return complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            if (call.modern)
            {
                append(writer, `"supportedVersions":`);
                writeSupported(writer);
                append(writer, ",");
            }
            else
                append(writer, `"protocolVersion":"2025-11-25",`);
            append(writer, `"capabilities":{"tools":{},"resources":{}}`);
            if (!call.modern)
            {
                append(writer, `,"serverInfo":`);
                writeInfo(writer, limits.name, limits.versionString);
            }
        });
    }

    private Reply list(ref scope RequestArena output, scope const ref Call call,
            scope const(ubyte)[] params, scope const ref ParamFields fields, bool selectTools) scope nothrow @nogc
    {
        size_t start;
        if (params.length != 0)
        {
            if (!fields.valid)
                return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP list parameters");
            if (fields.cursor.present())
            {
                char[40] value;
                size_t length;
                if (!readString(fields.cursor.get(params), value[], length))
                    return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP list cursor");
                start = registry.position(value[0 .. length], selectTools);
                if (start == size_t.max)
                    return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP list cursor");
            }
        }
        return complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            registry.emitPage(writer, selectTools, start);
        });
    }

    nothrow @nogc private Reply invoke(ref scope RequestArena work, ref scope RequestArena output,
            scope const ref Call call, scope const(ubyte)[] params, scope const ref ParamFields fields,
            ref Context context, scope BeginTool admitted) scope
    {
        char[maxResource] name;
        size_t length;
        if (!fields.valid || !readString(fields.name.get(params), name[], length))
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP tool name");
        const tool = registry.findTool(name[0 .. length]);
        if (tool.action is null)
            return fail(output, call.data.id, 400, invalidParameters, "Unknown MCP tool");
        const none = cast(const(ubyte)[]) "{}";
        const args = fields.arguments.present() ? fields.arguments.get(params) : none;
        const checked = tool.action(args, work, context, admitted);
        if (checked.badArguments)
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP tool arguments");
        if (!checked.result.ok())
            return toolError(output, call, checked.result.error.message);
        return encodeToolResult(work, output, call, checked.result.value);
    }

    private Reply encodeToolResult(ref scope RequestArena work, ref scope RequestArena output,
            scope const ref Call call, const ToolResult result) scope nothrow @nogc
    {
        // Validate provider JSON once; the measuring and writing passes then copy checked bytes.
        const blocks = result.content.length() == 0 ? Status.ok : checkJson(work, result.content, false);
        const fieldsStatus = result.structuredContent.length() == 0 ? Status.ok : checkJson(work,
                result.structuredContent, true);
        if (blocks != Status.ok || fieldsStatus != Status.ok)
            return fail(output, call.data.id, 500, internalError, "Invalid output from MCP tool provider");
        Status copied;
        auto response = complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, result.isError ? `"isError":true,"content":` : `"isError":false,"content":`);
            if (result.content.length() == 0)
                append(writer, "[]");
            else
                copied = appendRaw(work, result.content, writer);
            if (result.structuredContent.length() != 0)
            {
                append(writer, `,"structuredContent":`);
                const structured = appendRaw(work, result.structuredContent, writer);
                copied = copied == Status.ok ? structured : copied;
            }
        });
        if (copied != Status.ok)
            return fail(output, call.data.id, 500, internalError, "Invalid output from MCP tool provider");
        return response;
    }

    nothrow @nogc private Reply toolError(ref scope RequestArena output, scope const ref Call call, string reason) scope
    {
        return complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, `"isError":true,"content":[{"type":"text","text":`);
            quote(writer, reason.length ? reason : "Tool failed");
            append(writer, "}]");
        });
    }

    private Reply readResource(ref scope RequestArena work, ref scope RequestArena output,
            scope const ref Call call, scope const(ubyte)[] params, scope const ref ParamFields fields,
            ref Context context) scope nothrow @nogc
    {
        char[maxResource] uri;
        size_t length;
        if (!fields.valid || !readString(fields.uri.get(params), uri[], length))
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP resource URI");
        const resource = registry.findResource(uri[0 .. length]);
        if (resource.action is null)
            return fail(output, call.data.id, 404, -32_002, "MCP resource not found");
        const result = resource.action(work, context);
        if (!result.ok())
            return fail(output, call.data.id, 500, internalError, "MCP resource provider failed");
        Status resolved;
        auto reply = complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, `"contents":[{"uri":`);
            quote(writer, resource.info.uri);
            append(writer, `,"mimeType":`);
            quote(writer, resource.info.mimeType);
            append(writer, `,"text":`);
            resolved = work.read(result.value, (scope const(ubyte)[] text) @safe nothrow @nogc {
                writer.stringValue(text);
            });
            append(writer, "}]");
        });
        return resolved == Status.ok ? reply : fail(output, call.data.id, 500, internalError,
                "Invalid output from MCP resource provider");
    }

    nothrow @nogc private Reply complete(ref scope RequestArena arena, scope const ref Call call, scope Emit emit) scope
    {
        const encoded = pack(arena, limits.maxMessageBytes, (ref scope JsonWriter writer) @safe nothrow @nogc {
            writeId(writer, call.data.id);
            append(writer, `,"result":{`);
            if (call.modern)
                append(writer, `"resultType":"complete"`);
            if (emit !is null)
            {
                if (call.modern)
                    append(writer, ",");
                emit(writer);
            }
            if (call.modern)
                endModernResult(writer, limits.name, limits.versionString);
            else
                append(writer, "}}");
        });
        if (!encoded.ok())
            return fail(arena, call.data.id, 500, internalError, "MCP result exceeds its arena limit");
        return Reply(200, encoded.value);
    }

    nothrow @nogc private Reply versionFault(ref scope RequestArena output, scope const ref Identity id,
            scope const(char)[] requested) scope
    {
        return fail(output, id, 400, unsupportedVersion, "Unsupported MCP protocol version",
                (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, `,"data":{"supported":`);
            writeSupported(writer);
            append(writer, `,"requested":`);
            quote(writer, requested);
            append(writer, "}");
        });
    }

    private void writeSupported(ref scope JsonWriter writer) scope nothrow @nogc
    {
        append(writer, "[");
        if (supportsModern())
            quote(writer, modernRevision);
        if (supportsModern() && supportsLegacy())
            append(writer, ",");
        if (supportsLegacy())
            quote(writer, legacyRevision);
        append(writer, "]");
    }

    private Reply fail(ref scope RequestArena output, const Identity id, ushort status, int code,
            string description, scope Emit extra = null) scope nothrow @nogc
    {
        const encoded = pack(output, limits.maxMessageBytes, (ref scope JsonWriter writer) @safe nothrow @nogc {
            writeId(writer, id);
            append(writer, `,"error":{"code":`);
            writer.signedNumber(code);
            append(writer, `,"message":`);
            quote(writer, description);
            if (extra !is null)
                extra(writer);
            append(writer, "}}");
        });
        return Reply(status, encoded.value, SessionKey.init, false, encoded.error);
    }
}

nothrow @nogc private bool modernOpening(scope const ref Metadata meta,
        scope const ref Headers headers, scope const(char)[] verb) pure
{
    return meta.declared || headers.method.length != 0 || headers.name.length != 0
        || headers.release == modernRevision || verb == "server/discover";
}

nothrow @nogc private bool headerConflicts(scope const ref Envelope data, scope const ref Metadata meta,
        scope const ref Headers headers) pure
{
    return headers.release.length == 0 || headers.method != data.verb() || (meta.length != 0
            && headers.release != meta.revision());
}

nothrow @nogc private Status checkJson(ref scope RequestArena arena, Buffer handle, bool object)
{
    Status result;
    const code = arena.read(handle, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        if (object ? !isObject(bytes) : visitJsonArray(bytes,
            (scope const(ubyte)[])@safe nothrow @nogc => Error.init).code != Status.ok)
            result = Status.invalidArgument;
    });
    return code == Status.ok ? result : code;
}

nothrow @nogc private Status appendRaw(ref scope RequestArena arena, Buffer handle, ref scope JsonWriter writer)
{
    return arena.read(handle, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        writer.append(bytes);
    });
}

private bool matchingName(scope const(char)[] verb, scope const(ubyte)[] params,
        scope const ref ParamFields fields, scope const(char)[] wire) nothrow @nogc
{
    Range location;
    switch (verb)
    {
    case "tools/call", "prompts/get":
        location = fields.name;
        break;
    case "resources/read":
        location = fields.uri;
        break;
    default:
        return wire.length == 0;
    }
    char[maxResource] name;
    size_t length;
    return fields.valid && readString(location.get(params), name[], length) && length != 0
        && matchesHeader(wire, name[0 .. length]);
}
