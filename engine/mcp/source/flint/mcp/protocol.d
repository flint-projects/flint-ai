/// Shared registry dispatch, with distinct modern and legacy admission.
module flint.mcp.protocol;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.mcp.header_values : matchesHeader;
import flint.mcp.jsonrpc : Emit, Envelope, Identity, Range, append, decodeEnvelope, headerMismatch,
    internalError, invalidParameters, invalidRequest, isObject, malformed, maxMessage, maxResource,
    member, methodNotFound, pack, parseError, quote, readString, unsupportedVersion, writeId;
import flint.mcp.legacy : LegacyPhase, LegacySession, SessionKey, legacyRevision, validateInitialize;
import flint.mcp.modern : Metadata, endModernResult, metadata, modernRevision, writeInfo;
import flint.mcp.internal.registry : BeginTool, Registry;
import flint.mcp.types : McpOptions, ProtocolRevision;
import flint.serde : DecodeOptions;
import flint.serde.json_visit : visitJsonArray;
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
        if (!parsed.ok())
        {
            const fault = parsed.error.offset == size_t.max ? invalidRequest : parseError;
            return fail(output, Identity.init, 400, fault, "Invalid JSON-RPC request");
        }
        const data = parsed.value;
        if (data.methodLength == 0)
            return fail(output, Identity.init, 400, invalidRequest, "Expected a JSON-RPC request");
        const params = data.params.get(message);
        const meta = metadata(params);
        const verb = data.verb();

        if (meta.declared || headers.method.length != 0 || headers.name.length != 0
                || headers.release == modernRevision || verb == "server/discover")
            return modern(data, params, meta, headers, work, output, context, admitted);
        if (supportsLegacy() && (verb == "initialize" || headers.session.length != 0 || !headers.http
                && stdioPhase != LegacyPhase.initial))
            return legacy(data, params, headers, work, output, context, admitted);
        if (!supportsModern())
            return fail(output, data.id, 400, invalidRequest, "Legacy initialize is required");
        return modern(data, params, meta, headers, work, output, context, admitted);
    }

    private Reply modern(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref Metadata meta, scope const ref Headers headers, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope nothrow @nogc
    {
        if (!supportsModern())
            return fail(output, data.id, 400, methodNotFound, "Legacy initialize is required");
        if (headers.invalid || headers.http && (headers.release.length == 0
                || headers.method != data.verb() || meta.length != 0 && headers.release != meta.revision()))
            return fail(output, data.id, 400, headerMismatch, "MCP headers do not match the request");
        if (!meta.valid)
            return fail(output, data.id, 400, invalidParameters, "Missing or invalid MCP client metadata");
        if (meta.revision() != modernRevision)
            return versionFault(output, data.id, meta.revision());

        if (headers.http && !matchingName(data.verb(), params, headers.name))
            return fail(output, data.id, 400, headerMismatch, "Mcp-Name does not match the request");
        if (!data.id.present)
            return fail(output, Identity.init, 400, invalidRequest, "Modern MCP requires a request ID");
        return accept(Call(data, true), params, work, output, context, admitted);
    }

    private Reply legacy(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref Headers headers, ref scope RequestArena work, ref scope RequestArena output,
            ref Context context, scope BeginTool admitted) scope nothrow @nogc
    {
        if (headers.invalid)
            return fail(output, data.id, 400, invalidRequest, "Invalid legacy HTTP headers");
        if (data.verb() == "initialize")
            return initialize(data, params, headers, output);
        if (!headers.http)
            return legacyPhase(data, params, stdioPhase, work, output, context, admitted);
        if (headers.release.length != 0 && headers.release != legacyRevision)
            return fail(output, data.id, 400, invalidRequest, "Invalid legacy HTTP protocol version");
        if (headers.session.length == 0)
            return fail(output, data.id, 400, invalidRequest, "Mcp-Session-Id is required");
        foreach (ref session; sessions[0 .. limits.maxInFlight])
        {
            if (session.recognizes(headers.session))
                return legacyPhase(data, params, session.phase, work, output, context, admitted);
        }
        return fail(output, data.id, 404, invalidRequest, "Unknown legacy MCP session");
    }

    private Reply legacyPhase(scope const ref Envelope data, scope const(ubyte)[] params,
            ref LegacyPhase phase, ref scope RequestArena work, ref scope RequestArena output,
            ref Context context, scope BeginTool admitted) scope nothrow @nogc
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
        return accept(Call(data, false), params, work, output, context, admitted);
    }

    private Reply initialize(scope const ref Envelope data, scope const(ubyte)[] params,
            scope const ref Headers headers, ref scope RequestArena output) scope nothrow @nogc
    {
        if (!data.id.present || validateInitialize(params).code != Status.ok
                || headers.session.length || !headers.http && stdioPhase != LegacyPhase.initial)
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

    private Reply accept(const Call call, scope const(ubyte)[] params, ref scope RequestArena work,
            ref scope RequestArena output, ref Context context, scope BeginTool admitted) scope nothrow @nogc
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
            return list(output, call, params, true);
        case "resources/list":
            return list(output, call, params, false);
        case "tools/call":
            return invoke(work, output, call, params, context, admitted);
        case "resources/read":
            return readResource(work, output, call, params, context);
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
            scope const(ubyte)[] params, bool selectTools) scope nothrow @nogc
    {
        size_t start;
        if (params.length != 0)
        {
            const cursor = member(params, "cursor");
            if (!cursor.ok())
                return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP list parameters");
            if (cursor.value.present())
            {
                char[40] value;
                size_t length;
                if (!readString(cursor.value.get(params), value[], length))
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

    private Reply invoke(ref scope RequestArena work, ref scope RequestArena output,
            scope const ref Call call, scope const(ubyte)[] params, ref Context context, scope BeginTool admitted) scope nothrow @nogc
    {
        const location = member(params, "name");
        char[maxResource] name;
        size_t length;
        if (!location.ok() || !readString(location.value.get(params), name[], length))
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP tool name");
        const tool = registry.findTool(name[0 .. length]);
        if (tool.action is null)
            return fail(output, call.data.id, 400, invalidParameters, "Unknown MCP tool");
        const fields = member(params, "arguments");
        if (!fields.ok())
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP tool arguments");
        const none = cast(const(ubyte)[]) "{}";
        const args = fields.value.present() ? fields.value.get(params) : none;
        const checked = tool.action(args, work, context, admitted);
        if (checked.badArguments)
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP tool arguments");
        if (!checked.result.ok())
            return toolError(output, call, checked.result.error.message);
        Status blocks;
        Status fieldsStatus;
        const result = checked.result.value;
        auto response = complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, result.isError ? `"isError":true,"content":` : `"isError":false,"content":`);
            if (result.content.length() == 0)
                append(writer, "[]");
            else
                blocks = appendChecked(work, result.content, writer, false);
            if (result.structuredContent.length() != 0)
            {
                append(writer, `,"structuredContent":`);
                fieldsStatus = appendChecked(work, result.structuredContent, writer, true);
            }
        });
        if (blocks != Status.ok || fieldsStatus != Status.ok)
            return fail(output, call.data.id, 500, internalError, "Invalid output from MCP tool provider");
        return response;
    }

    private Reply toolError(ref scope RequestArena output, scope const ref Call call, string description) scope nothrow @nogc
    {
        return complete(output, call, (ref scope JsonWriter writer) @safe nothrow @nogc {
            append(writer, `"isError":true,"content":[{"type":"text","text":`);
            quote(writer, description.length ? description : "Tool failed");
            append(writer, "}]");
        });
    }

    private Reply readResource(ref scope RequestArena work, ref scope RequestArena output,
            scope const ref Call call, scope const(ubyte)[] params, ref Context context) scope nothrow @nogc
    {
        const location = member(params, "uri");
        char[maxResource] uri;
        size_t length;
        if (!location.ok() || !readString(location.value.get(params), uri[], length))
            return fail(output, call.data.id, 400, invalidParameters, "Invalid MCP resource URI");
        const resource = registry.findResource(uri[0 .. length]);
        if (resource.action is null)
            return fail(output, call.data.id, 404, -32002, "MCP resource not found");
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

    private Reply complete(ref scope RequestArena output, scope const ref Call call, scope Emit writeFields) scope nothrow @nogc
    {
        const encoded = pack(output, limits.maxMessageBytes, (ref scope JsonWriter writer) @safe nothrow @nogc {
            writeId(writer, call.data.id);
            append(writer, `,"result":{`);
            if (call.modern)
                append(writer, `"resultType":"complete"`);
            if (writeFields !is null)
            {
                if (call.modern)
                    append(writer, ",");
                writeFields(writer);
            }
            if (call.modern)
                endModernResult(writer, limits.name, limits.versionString);
            else
                append(writer, "}}");
        });
        if (!encoded.ok())
            return fail(output, call.data.id, 500, internalError, "MCP result exceeds its output limit");
        return Reply(200, encoded.value);
    }

    private Reply versionFault(ref scope RequestArena output, scope const ref Identity id, scope const(char)[] requested) scope nothrow @nogc
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

private Status appendChecked(ref scope RequestArena arena, Buffer handle, ref scope JsonWriter writer, bool object) nothrow @nogc
{
    Status result;
    const code = arena.read(handle, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
        if (object ? !isObject(bytes) : visitJsonArray(bytes,
            (scope const(ubyte)[] unused)@safe nothrow @nogc => Error.init).code != Status.ok)
            result = Status.invalidArgument;
        else
            writer.append(bytes);
    });
    return code == Status.ok ? result : code;
}

private bool matchingName(scope const(char)[] verb, scope const(ubyte)[] params, scope const(char)[] wire) nothrow @nogc
{
    string key;
    switch (verb)
    {
    case "tools/call", "prompts/get":
        key = "name";
        break;
    case "resources/read":
        key = "uri";
        break;
    default:
        return wire.length == 0;
    }
    const location = member(params, key);
    char[maxResource] name;
    size_t length;
    return location.ok() && readString(location.value.get(params), name[], length) && length != 0
        && matchesHeader(wire, name[0 .. length]);
}
