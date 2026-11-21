/// Pinned-revision MCP HTTP and subprocess client.
module flint.mcp.client;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.http : ClientOptions, HttpClient, HttpMethod, HttpRequestView, HttpResponse, HttpStreamField;
import flint.mcp.header_values : encodeHeader;
import flint.mcp.http : equalName, includes;
import flint.mcp.jsonrpc : Emit, Envelope, Identity, Range, append, decodeEnvelope, headerMismatch,
    isObject, isString, malformed, maxMessage, maxMethod, maxResource, member, missingCapability,
    pack, quote, readString, unsupportedVersion, writeId;
import flint.mcp.legacy : initialized, legacyRevision, writeInitialize;
import flint.mcp.modern : modernRevision, writeClientMeta;
import flint.mcp.mrtr : asksForInput, prepareInput;
import flint.mcp.params : EncodedField, ParamRules, maximumHeaders;
import flint.mcp.internal.registry : validText;
import flint.mcp.stdio : LineReader, sendFrame;
import flint.mcp.sys.stdio : Child;
import flint.mcp.sys.storage : releaseStorage, reserveStorage;
import flint.mcp.types : McpClientOptions, McpProcessOptions, ProtocolRevision, ToolResult;
import flint.serde : decodeInto;
import flint.serde.json_visit : visitJsonArray;
import flint.serde.json_write : JsonWriter;

@safe:

/// Owner-confined MCP client. Returned handles belong to the caller's request arena.
struct McpClient
{
    private ClientDriver driver;

    @disable this(this);

    /// Connect to HTTPS, explicit HTTP loopback, or a stdio:/absolute/path subprocess.
    Error connect(string endpoint, ProtocolRevision revision, ref Context context)
    {
        McpClientOptions options;
        options.revision = revision;
        options.acceptLegacy = revision == ProtocolRevision.modern20260728;
        return connectWith(endpoint, options, context);
    }

    /// Connect with explicit TLS roots, authorization and revision policy.
    Error connectWith(string endpoint, McpClientOptions options, ref Context context)
    {
        if (endpoint.length > 6 && endpoint[0 .. 6] == "stdio:")
            return connectProcess(McpProcessOptions(endpoint[6 .. $]), options, context);
        if (driver !is null)
            return Error(Status.conflict, "MCP client is already connected");
        if (!validEndpoint(endpoint) || !validOptions(options))
            return malformed("invalid MCP HTTP endpoint or client options");
        auto transport = new ClientDriver(options);
        const opened = transport.openHttp(endpoint);
        return finishConnect(transport, opened, context);
    }

    /// Launch the explicit executable and use only the supplied argv and environment.
    Error connectProcess(McpProcessOptions process, McpClientOptions options, ref Context context)
    {
        if (driver !is null)
            return Error(Status.conflict, "MCP client is already connected");
        if (!validOptions(options))
            return malformed("invalid MCP client options");
        auto transport = new ClientDriver(options);
        const opened = transport.openProcess(process);
        return finishConnect(transport, opened, context);
    }

    private Error finishConnect(ClientDriver transport, Error opened, ref Context context) nothrow @nogc
    {
        const checked = opened.code == Status.ok ? transport.negotiate(context) : opened;
        if (checked.code == Status.ok)
        {
            driver = transport;
            return Error.init;
        }
        Context cleanup;
        const stopped = transport.close(cleanup);
        if (stopped.code == Status.timedOut || stopped.code == Status.conflict)
            driver = transport;
        return checked;
    }

    /// Return the first tools page as the JSON result object.
    Result!Buffer listTools(ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return listToolsPage(null, arena, context);
    }

    /// Return the page selected by the server's previous nextCursor.
    nothrow @nogc Result!Buffer listToolsPage(scope const(char)[] cursor, ref scope RequestArena arena,
            ref Context context)
    {
        if (driver is null)
            return Result!Buffer(Buffer.init, closed());
        if (!validText(cursor, 1024, true))
            return Result!Buffer(Buffer.init, malformed("invalid MCP list cursor"));
        return driver.simple("tools/list", null, null, cursor, arena, context);
    }

    /// Return the first resources page as the JSON result object.
    Result!Buffer listResources(ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        return listResourcesPage(null, arena, context);
    }

    /// Return a resource page selected by the server's previous nextCursor.
    nothrow @nogc Result!Buffer listResourcesPage(scope const(char)[] cursor,
            ref scope RequestArena arena, ref Context context)
    {
        if (driver is null)
            return Result!Buffer(Buffer.init, closed());
        if (!validText(cursor, 1024, true))
            return Result!Buffer(Buffer.init, malformed("invalid MCP list cursor"));
        return driver.simple("resources/list", null, null, cursor, arena, context);
    }

    /// Decode a tool result and resolve content handles into the caller's arena.
    Result!ToolResult callTool(string name, scope const(ubyte)[] arguments,
            ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        if (driver is null)
            return Result!ToolResult(ToolResult.init, closed());
        if (!validText(name, maxMethod) || (arguments.length && !isObject(arguments)))
            return Result!ToolResult(ToolResult.init, malformed("invalid MCP tool name or arguments"));
        return driver.call(name, arguments, arena, context);
    }

    /// Read an explicitly named resource and return its result object.
    Result!Buffer readResource(string uri, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        if (driver is null)
            return Result!Buffer(Buffer.init, closed());
        if (!validText(uri, maxResource))
            return Result!Buffer(Buffer.init, malformed("invalid MCP resource URI"));
        return driver.simple("resources/read", "uri", uri, null, arena, context);
    }

    /// End the optional legacy session or join the owned subprocess.
    Error close(ref Context context) nothrow @nogc
    {
        if (driver is null)
            return Error.init;
        const result = driver.close(context);
        if (result.code != Status.timedOut && result.code != Status.conflict)
            driver = null;
        return result;
    }
}

private enum headerBudget = 65_536;

private struct ClientReply
{
    Envelope envelope;
    size_t length;
    ushort status;
    Error error;
}

private final class ClientDriver
{
    private McpClientOptions settings;
    private ProtocolRevision release;
    private HttpClient http;
    private string url;
    private Child child;
    private LineReader reader;
    private ubyte[] memory;
    private ubyte[] wire;
    private ubyte[] received;
    private ubyte[] compact;
    private ubyte[] response;
    private char[256] session;
    private size_t sessionLength;
    private long nextId;
    private string cachedTool;
    private ParamRules rules;
    private EncodedField[maximumHeaders] mirrored;
    private size_t mirrorCount;
    private char[1536] encodedName;
    private HttpStreamField[maximumHeaders + 7] outgoing;
    private bool ready;
    private bool busy;

    this(McpClientOptions options)
    {
        settings = options;
        release = options.revision;
    }

    Error openHttp(string endpoint)
    {
        ClientOptions options;
        options.maxConnections = 2;
        options.maxConnectionsPerOrigin = 2;
        options.maxResponseBytes = settings.maxMessageBytes + headerBudget;
        options.caBundle = settings.caBundle;

        const reserved = reserve();
        if (reserved.code != Status.ok)
            return reserved;
        const opened = http.open(options);
        if (opened.code == Status.ok)
            url = endpoint;
        return opened;
    }

    Error openProcess(McpProcessOptions process)
    {
        const reserved = reserve();
        return reserved.code == Status.ok ? child.open(process) : reserved;
    }

    private Error reserve() nothrow @nogc
    {
        const maximum = settings.maxMessageBytes;
        memory = reserveStorage(maximum * 4 + 2 * headerBudget + 32);
        if (memory is null)
            return Error(Status.outOfMemory, "unable to reserve MCP client storage");
        wire = memory[0 .. maximum];
        compact = memory[maximum .. maximum * 2];
        received = memory[maximum * 2 .. maximum * 3 + 1];
        response = memory[maximum * 3 + 1 .. $];
        return Error.init;
    }

    Error negotiate(ref Context context) nothrow @nogc
    {
        if (release == ProtocolRevision.legacy20251125)
            return connectLegacy(context);

        auto probe = !url.length && settings.acceptLegacy
            ? context.withDeadline(Deadline.afterMillis(750)) : context.withDeadline(Deadline.none());
        const first = transact("server/discover", null, null, null, null, false, probe);
        if (first.error.code == Status.ok && supportsDiscovery(first))
        {
            ready = true;
            return Error.init;
        }

        const fault = first.envelope.fault.get(received[0 .. first.length]);
        const code = faultNumber(fault);
        if (code == unsupportedVersion)
        {
            if (settings.acceptLegacy && advertisesLegacy(fault))
                return connectLegacy(context);
            return Error(Status.unsupported, "MCP peer has no supported modern protocol version");
        }
        if (isModernFault(code) || !settings.acceptLegacy || context.cancelled())
            return checkedError(first, "MCP modern protocol negotiation failed");
        if (legacyFallback(first, code))
            return connectLegacy(context);
        return checkedError(first, "MCP server did not return a discovery result");
    }

    private bool supportsDiscovery(scope const ref ClientReply first) scope nothrow @nogc
    {
        const document = first.envelope.result.get(received[0 .. first.length]);
        return document.length != 0 && namedVersion(document, "supportedVersions", modernRevision)
            && objectField(document, "capabilities");
    }

    private bool legacyFallback(scope const ref ClientReply reply, int code) const scope pure nothrow @nogc
    {
        if (!url.length)
            return code != 0 || reply.error.code == Status.timedOut;
        return reply.status >= 400 && reply.status < 500 && reply.status != 401 && reply.status != 403;
    }

    private Error connectLegacy(ref Context context) nothrow @nogc
    {
        release = ProtocolRevision.legacy20251125;
        const first = transact("initialize", null, null, null, null, false, context);
        if (first.error.code != Status.ok || !initialized(first.envelope.result.get(received[0 .. first.length])))
            return checkedError(first, "MCP peer rejected the legacy protocol revision");
        const notified = transact("notifications/initialized", null, null, null, null, true, context);
        if (notified.error.code != Status.ok || notified.status != 202)
            return checkedError(notified, "Legacy MCP initialized notification was rejected");
        ready = true;
        return Error.init;
    }

    Result!Buffer simple(string method, string key, scope const(char)[] value,
            scope const(char)[] cursor, ref scope RequestArena arena, ref Context context) nothrow @nogc
    {
        const held = enter();
        if (held.code != Status.ok)
            return Result!Buffer(Buffer.init, held);
        scope (exit)
            busy = false;
        const response = operation(method, key, value, null, cursor, context);
        const checked = success(response);
        return checked.code == Status.ok
            ? arena.copyIn(response.envelope.result.get(received[0 .. response.length])) : Result!Buffer(Buffer.init,
                    checked);
    }

    nothrow @nogc Result!ToolResult call(string name, scope const(ubyte)[] arguments,
            ref scope RequestArena arena, ref Context context)
    {
        const held = enter();
        if (held.code != Status.ok)
            return Result!ToolResult(ToolResult.init, held);
        scope (exit)
            busy = false;
        const mirroredCall = url.length && release == ProtocolRevision.modern20260728;
        mirrorCount = 0;
        if (mirroredCall)
        {
            const prepared = prepareHeaders(name, arguments, context);
            if (prepared.code != Status.ok)
                return Result!ToolResult(ToolResult.init, prepared);
        }
        auto response = operation("tools/call", "name", name, arguments, null, context);
        if (mirroredCall && response.status == 400
                && faultNumber(response.envelope.fault.get(received[0 .. response.length])) == headerMismatch)
        {
            cachedTool = null;
            const refreshed = prepareHeaders(name, arguments, context);
            if (refreshed.code != Status.ok)
                return Result!ToolResult(ToolResult.init, refreshed);
            response = operation("tools/call", "name", name, arguments, null, context);
        }
        const checked = success(response);
        if (checked.code != Status.ok)
            return Result!ToolResult(ToolResult.init, checked);
        return readToolResult(response.envelope.result.get(received[0 .. response.length]), arena);
    }

    private Error prepareHeaders(string tool, scope const(ubyte)[] args, ref Context context) nothrow @nogc
    {
        if (cachedTool != tool)
        {
            const loaded = loadRules(tool, context);
            if (loaded.code != Status.ok)
                return loaded;
        }
        mirrorCount = 0;
        return args.length ? rules.apply(args, mirrored[], mirrorCount) : Error.init;
    }

    private Error loadRules(string tool, ref Context context) nothrow @nogc
    {
        cachedTool = null;
        rules = ParamRules.init;
        char[1024] cursor;
        size_t cursorLength;
        enum maximumPages = 128;
        foreach (page; 0 .. maximumPages)
        {
            const list = transact("tools/list", null, null, null, cursor[0 .. cursorLength], false, context);
            const accepted = success(list);
            if (accepted.code != Status.ok)
                return accepted;
            const document = list.envelope.result.get(received[0 .. list.length]);
            const walked = scanTools(document, tool);
            if (!walked.ok())
                return walked.error;
            const next = member(document, "nextCursor");
            if (!next.ok())
                return next.error;
            if (walked.value || !next.value.present())
            {
                cachedTool = tool;
                return Error.init;
            }
            if (!readString(next.value.get(document), cursor[], cursorLength) || cursorLength == 0)
                return malformed("MCP tools/list returned an invalid cursor");
        }
        return Error(Status.resourceExhausted, "MCP tools/list pagination limit reached");
    }

    private Result!bool scanTools(scope const(ubyte)[] document, string tool) nothrow @nogc
    {
        const tools = member(document, "tools");
        if (!tools.ok() || !tools.value.present())
            return Result!bool(false, malformed("MCP tools/list did not return tool definitions"));

        bool found;
        const checked = visitJsonArray(tools.value.get(document), (scope const(ubyte)[] entry) @safe nothrow @nogc {
            const name = member(entry, "name");
            if (!name.ok() || !isString(name.value.get(entry), tool))
                return Error.init;
            if (found)
                return malformed("duplicate MCP tool definition");
            const schema = member(entry, "inputSchema");
            if (!schema.ok() || !schema.value.present())
                return malformed("MCP tool definition did not include an input schema");
            found = true;
            return rules.readSchema(schema.value.get(entry));
        });
        return Result!bool(found, checked);
    }

    private Error enter() nothrow @nogc
    {
        if (!ready || busy)
            return Error(Status.conflict, "MCP client is closed or already calling");
        busy = true;
        return Error.init;
    }

    private Error success(const ClientReply result) scope nothrow @nogc
    {
        if (result.error.code != Status.ok || result.status >= 400 || !result.envelope.result.present())
            return checkedError(result, "MCP operation returned a protocol error");
        if (release == ProtocolRevision.modern20260728)
        {
            const document = result.envelope.result.get(received[0 .. result.length]);
            const flavour = member(document, "resultType");
            if (!flavour.ok() || (flavour.value.present() && !isString(flavour.value.get(document), "complete")))
                return Error(Status.unsupported, "MCP result requires an unsupported input round");
        }
        return Error.init;
    }

    private ClientReply operation(string method, string key, scope const(char)[] value,
            scope const(ubyte)[] args, scope const(char)[] cursor, ref Context context) nothrow @nogc
    {
        auto result = transact(method, key, value, args, cursor, false, context);
        if (release != ProtocolRevision.modern20260728 || (method != "tools/call" && method != "resources/read"))
            return result;
        for (uint round; result.error.code == Status.ok && result.status < 300; ++round)
        {
            const document = result.envelope.result.get(received[0 .. result.length]);
            if (!asksForInput(document))
                break;
            if (round == settings.maxInputRounds)
                return failed(Error(Status.resourceExhausted, "MCP input round limit reached"));

            const prepared = nextInput(document, context);
            if (!prepared.ok())
                return failed(prepared.error);
            result = transact(method, key, value, args, cursor, false, context, compact[0 .. prepared.value]);
        }
        return result;
    }

    private Result!size_t nextInput(scope const(ubyte)[] body, ref Context context) nothrow @nogc
    {
        auto work = RequestArena(wire);
        auto replyArena = RequestArena(response);
        const encoded = prepareInput(body, settings.maxMessageBytes, settings.elicitation, work, replyArena, context);
        if (!encoded.ok())
            return Result!size_t(0, encoded.error);
        // The retry serializes these parameters before either transport reuses its buffers.
        const copied = replyArena.read(encoded.value, (scope const(ubyte)[] raw) @safe nothrow @nogc {
            compact[0 .. raw.length] = raw;
        });
        return copied == Status.ok ? Result!size_t(encoded.value.length()) : Result!size_t(0,
                Error(copied, "MCP input round expired before retry"));
    }

    private ClientReply transact(string method, string key, scope const(char)[] value,
            scope const(ubyte)[] args, scope const(char)[] cursor, bool notification,
            ref Context context, scope const(ubyte)[] extra = null) nothrow @nogc
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return failed(checked);
        Identity id;
        if (!notification)
        {
            if (nextId == long.max)
                return failed(Error(Status.resourceExhausted, "MCP client exhausted request IDs"));
            id.present = true;
            id.number = ++nextId;
        }
        auto writer = RequestArena(wire);
        const encoded = pack(writer, settings.maxMessageBytes, (ref scope JsonWriter output) @safe nothrow @nogc {
            if (notification)
                append(output, `{"jsonrpc":"2.0"`);
            else
                writeId(output, id);
            append(output, `,"method":`);
            quote(output, method);
            emitParams(output, method, key, value, args, cursor, extra);
            append(output, "}");
        });
        if (!encoded.ok())
            return failed(encoded.error);

        ClientReply reply;
        const borrowed = writer.read(encoded.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            reply = url.length ? sendHttp(bytes, method, value, id, context) : sendStdio(bytes, id, context);
        });
        return borrowed == Status.ok ? reply : failed(Error(borrowed, "MCP sent buffer was not available"));
    }

    nothrow @nogc private void emitParams(ref scope JsonWriter output, string method, string key,
            scope const(char)[] value, scope const(ubyte)[] args, scope const(char)[] page, scope const(ubyte)[] tail)
    {
        if (method == "notifications/initialized")
            return;
        const modern = release == ProtocolRevision.modern20260728;
        append(output, `,"params":{`);
        if (modern)
            writeClientMeta(output, settings.elicitation !is null);
        if (method == "initialize")
            writeInitialize(output);
        if (key.length != 0 || page.length != 0)
        {
            if (modern)
                append(output, ",");
            quote(output, page.length ? "cursor" : key);
            append(output, ":");
            quote(output, page.length ? page : value);
        }
        if (args.length != 0)
        {
            append(output, `,"arguments":`);
            output.append(args);
        }
        output.append(tail);
        append(output, "}");
    }

    nothrow @nogc private ClientReply sendStdio(scope const(ubyte)[] body,
            scope const ref Identity expected, ref Context context)
    {
        const sent = sendFrame(child.input, child.diagnostic, body, compact, context);
        if (sent.code != Status.ok)
            return failed(sent);
        if (!expected.present)
            return ClientReply(Envelope.init, 0, 202);
        for (;;)
        {
            const line = reader.receive(child.output, child.diagnostic, received, context);
            if (!line.ok())
            {
                if (line.error.code == Status.cancelled || line.error.code == Status.timedOut)
                    sendCancel(expected);
                return failed(line.error);
            }
            if (line.value == 0)
                return failed(Error(Status.unavailable, "MCP subprocess closed stdout"));
            const parsed = decodeEnvelope(received[0 .. line.value], settings.maxMessageBytes);
            if (!parsed.ok())
                return failed(parsed.error);
            if (earlierReply(parsed.value, expected))
                continue;
            return correlate(parsed, line.value, expected, 200);
        }
    }

    private ClientReply sendHttp(scope const(ubyte)[] body, string method, scope const(char)[] name,
            scope const ref Identity expected, ref Context context) nothrow @nogc
    {
        auto scratch = RequestArena(response);
        const modern = release == ProtocolRevision.modern20260728;
        size_t nameLength;
        if (modern && name.length && method != "tools/list" && method != "resources/list"
                && !encodeHeader(name, encodedName[], nameLength))
            return failed(malformed("MCP name exceeds the HTTP field limit"));
        auto fieldCount = collectHeaders(method, modern, nameLength);
        scope auto view = HttpRequestView(HttpMethod.post, url, outgoing[0 .. fieldCount], body);
        const transferred = http.sendView(view, scratch, context);
        if (!transferred.ok())
        {
            if (!modern && expected.present && sessionLength
                    && (transferred.error.code == Status.cancelled || transferred.error.code == Status.timedOut))
                sendCancel(expected);
            return failed(transferred.error);
        }
        return parseHttp(scratch, transferred.value, expected, method);
    }

    private size_t collectHeaders(string method, bool modern, size_t nameLength) nothrow @nogc
    {
        size_t count;
        outgoing[count++] = HttpStreamField("content-type", "application/json");
        outgoing[count++] = HttpStreamField("accept", "application/json, text/event-stream");
        outgoing[count++] = HttpStreamField("mcp-protocol-version", modern ? modernRevision : legacyRevision);
        if (modern)
            outgoing[count++] = HttpStreamField("mcp-method", method);
        else if (sessionLength)
            outgoing[count++] = HttpStreamField("mcp-session-id", session[0 .. sessionLength]);
        if (nameLength)
            outgoing[count++] = HttpStreamField("mcp-name", encodedName[0 .. nameLength]);
        if (settings.authorization.length)
            outgoing[count++] = HttpStreamField("authorization", settings.authorization);
        if (modern && method == "tools/call")
        {
            foreach (ref field; mirrored[0 .. mirrorCount])
            {
                outgoing[count++] = HttpStreamField(field.name[0 .. field.nameLength],
                        field.value[0 .. field.valueLength]);
            }
        }
        return count;
    }

    private ClientReply parseHttp(ref scope RequestArena arena,
            scope const ref HttpResponse transferResult, scope const ref Identity expected, string method) nothrow @nogc
    {
        const status = transferResult.status;
        if (status == 401 || status == 403)
            return failed(Error(Status.permissionDenied, "MCP endpoint rejected authorization"), status);
        if (!expected.present)
            return ClientReply(Envelope.init, 0, status);
        bool events;
        bool json;
        if (transferResult.headers != Buffer.init)
        {
            const headers = arena.read(transferResult.headers, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                inspectHeaders(bytes, method == "initialize" && status < 300, json, events);
            });
            if (headers != Status.ok)
                return failed(Error(headers, "MCP HTTP headers expired"), status);
        }
        if ((!events && !json) || transferResult.body.length() == 0)
            return failed(malformed("MCP HTTP reply lacks a supported content type or body"), status);
        ClientReply parsed;
        const borrowed = arena.read(transferResult.body, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            parsed = events ? eventReply(bytes, expected, status) : jsonReply(bytes, expected, status);
        });
        return borrowed == Status.ok ? parsed : failed(Error(borrowed, "MCP HTTP response body expired"), status);
    }

    nothrow @nogc private void inspectHeaders(scope const(ubyte)[] bytes, bool initialization,
            out bool json, out bool events)
    {
        const contentType = responseHeader(bytes, "content-type");
        const value = cast(const(char)[]) contentType.get(bytes);
        json = includes(value, "application/json", ';');
        events = includes(value, "text/event-stream", ';');
        if (!initialization)
            return;
        const token = responseHeader(bytes, "mcp-session-id").get(bytes);
        if (validSession(token))
        {
            sessionLength = token.length;
            session[0 .. sessionLength] = cast(const(char)[]) token;
        }
    }

    nothrow @nogc private ClientReply jsonReply(scope const(ubyte)[] bytes, scope const ref Identity expected,
            ushort status)
    {
        if (bytes.length > settings.maxMessageBytes)
            return failed(Error(Status.resourceExhausted, "MCP HTTP envelope exceeded its limit"), status);
        received[0 .. bytes.length] = bytes;
        return correlate(decodeEnvelope(bytes, settings.maxMessageBytes), bytes.length, expected, status);
    }

    nothrow @nogc private ClientReply eventReply(scope const(ubyte)[] stream,
            scope const ref Identity expected, ushort status)
    {
        size_t length;
        bool data;
        EventLines lines;
        Range lineRange;
        while (lines.next(stream, lineRange))
        {
            const line = lineRange.get(stream);
            if (!line.length)
            {
                if (data)
                {
                    const frame = received[0 .. length];
                    const parsed = decodeEnvelope(frame, settings.maxMessageBytes);
                    if (!parsed.ok() || parsed.value.id.present || parsed.value.methodLength == 0)
                        return correlate(parsed, length, expected, status);
                }
                length = 0;
                data = false;
                continue;
            }
            if (line.length < 5 || line[0 .. 5] != cast(const(ubyte)[]) "data:")
                continue;
            auto value = line[5 .. $];
            if (value.length && value[0] == ' ')
                value = value[1 .. $];
            const overhead = data ? 1 : 0;
            if (length + overhead > settings.maxMessageBytes || value.length
                    > settings.maxMessageBytes - length - overhead)
                return failed(Error(Status.resourceExhausted, "MCP event exceeded its byte limit"), status);
            if (data)
                received[length++] = '\n';
            received[length .. length + value.length] = value;
            length += value.length;
            data = true;
        }
        return failed(malformed("MCP event stream ended before its correlated response"), status);
    }

    private void sendCancel(scope const ref Identity id) nothrow @nogc
    {
        ubyte[1024] raw;
        auto arena = RequestArena(raw[]);
        const notice = pack(arena, raw.length, (ref scope JsonWriter output) @safe nothrow @nogc {
            append(output, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":`);
            id.encode(output);
            append(output, "}}");
        });
        if (!notice.ok())
            return;
        Context independent;
        auto context = independent.withDeadline(Deadline.afterMillis(250));
        arena.read(notice.value, (scope const(ubyte)[] message) @safe nothrow @nogc {
            if (url.length)
            {
                const noResponse = Identity.init;
                sendHttp(message, "notifications/cancelled", null, noResponse, context);
            }
            else
                sendFrame(child.input, child.diagnostic, message, compact, context);
        });
    }

    Error close(ref Context context) nothrow @nogc
    {
        if (busy)
            return Error(Status.conflict, "MCP request is still active");
        if (legacySessionOpen() && !context.cancelled())
            endLegacySession(context);
        const closed = url.length ? http.close() : child.stop(context);
        if (closed.code != Status.timedOut && closed.code != Status.conflict)
        {
            releaseStorage(memory);
            wire = null;
            compact = null;
            received = null;
            response = null;
        }
        return closed;
    }

    private bool legacySessionOpen() const scope pure nothrow @nogc
    {
        return url.length && ready && release == ProtocolRevision.legacy20251125 && sessionLength;
    }

    private void endLegacySession(ref Context context) nothrow @nogc
    {
        scope const HttpStreamField[] fields = [
            HttpStreamField("mcp-protocol-version", legacyRevision),
            HttpStreamField("mcp-session-id", session[0 .. sessionLength]),
            HttpStreamField("authorization", settings.authorization),
        ];
        scope const view = HttpRequestView(HttpMethod.delete_, url, fields[0 .. settings.authorization.length ? 3 : 2]);
        auto arena = RequestArena(response);
        http.sendView(view, arena, context);
        ready = false;
    }

}

private struct EventLines
{
    size_t start;
    bool next(scope const(ubyte)[] stream, out Range line) nothrow @nogc
    {
        size_t end = start;
        while (end < stream.length && stream[end] != '\n' && stream[end] != '\r')
            ++end;
        if (end == stream.length)
            return false;
        line = Range(start, end - start);
        start = end + 1;
        if (start < stream.length && stream[end] == '\r' && stream[start] == '\n')
            ++start;
        return true;
    }
}

private bool earlierReply(scope const ref Envelope reply, scope const ref Identity expected) pure nothrow @nogc
{
    if (!reply.id.present)
        return reply.methodLength != 0;
    return !reply.id.quoted && reply.id.number < expected.number;
}

private bool advertisesLegacy(scope const(ubyte)[] fault) nothrow @nogc
{
    const details = member(fault, "data");
    if (!details.ok())
        return false;
    const versions = details.value.get(fault);
    return namedVersion(versions, "supported", legacyRevision) && !namedVersion(versions, "supported", modernRevision);
}

private Error closed() pure nothrow @nogc
{
    return Error(Status.conflict, "MCP client is closed");
}

private ClientReply failed(Error error, ushort status = 0) pure nothrow @nogc
{
    return ClientReply(Envelope.init, 0, status, error);
}

nothrow @nogc private ClientReply correlate(Result!Envelope parsed, size_t length,
        scope const ref Identity expected, ushort status)
{
    if (!parsed.ok())
        return failed(parsed.error, status);
    const uncorrelatedError = status >= 400 && parsed.value.fault.present() && !parsed.value.id.present;
    if (parsed.value.methodLength || (!parsed.value.id.matches(expected) && !uncorrelatedError))
        return failed(malformed("MCP reply does not match request ID"), status);
    return ClientReply(parsed.value, length, status);
}

private Error checkedError(const ClientReply reply, string description) pure nothrow @nogc
{
    return reply.error.code != Status.ok ? reply.error : Error(Status.invalidArgument, description);
}

private bool namedVersion(scope const(ubyte)[] body, string key, string expected) nothrow @nogc
{
    const found = member(body, key);
    if (!found.ok())
        return false;
    bool supported;
    const parsed = visitJsonArray(found.value.get(body), (scope const(ubyte)[] value) @safe nothrow @nogc {
        supported |= isString(value, expected);
        return Error.init;
    });
    return parsed.code == Status.ok && supported;
}

private bool objectField(scope const(ubyte)[] body, string key) nothrow @nogc
{
    const found = member(body, key);
    return found.ok() && isObject(found.value.get(body));
}

private int faultNumber(scope const(ubyte)[] body) nothrow @nogc
{
    const code = member(body, "code");
    if (!code.ok())
        return 0;
    RequestArena scratch;
    int[1] number;
    const decoded = decodeInto(code.value.get(body), number[0], scratch);
    return decoded.code == Status.ok ? number[0] : 0;
}

private bool isModernFault(int code) pure nothrow @nogc
{
    return code == headerMismatch || code == missingCapability || code == unsupportedVersion;
}

private Result!ToolResult readToolResult(scope const(ubyte)[] wire, ref scope RequestArena arena) nothrow @nogc
{
    const content = member(wire, "content");
    const fields = member(wire, "structuredContent");
    const flag = member(wire, "isError");
    if (!content.ok() || !fields.ok() || !flag.ok() || (!content.value.present() && !fields.value.present()))
        return Result!ToolResult(ToolResult.init, malformed("malformed MCP tool result"));
    const blocks = content.value.present() ? content.value.get(wire) : cast(const(ubyte)[]) "[]";
    if (visitJsonArray(blocks, (scope const(ubyte)[])@safe nothrow @nogc => Error.init).code != Status.ok)
        return Result!ToolResult(ToolResult.init, malformed("malformed MCP result content"));
    const structured = fields.value.get(wire);
    if (structured.length && !isObject(structured))
        return Result!ToolResult(ToolResult.init, malformed("malformed MCP result structured content"));
    ToolResult output;
    if (flag.value.present())
    {
        RequestArena scratch;
        const decoded = decodeInto(flag.value.get(wire), output.isError, scratch);
        if (decoded.code != Status.ok)
            return Result!ToolResult(ToolResult.init, decoded);
    }
    return copyToolContent(blocks, structured, output, arena);
}

private Result!ToolResult copyToolContent(scope const(ubyte)[] blocks, scope const(ubyte)[] structured,
        ToolResult output, ref scope RequestArena arena) nothrow @nogc
{
    if (blocks.length + structured.length + 16 > arena.stats().capacity - arena.stats().used)
        return Result!ToolResult(ToolResult.init, Error(Status.outOfMemory, "MCP result exceeds caller storage"));
    const copied = arena.copyIn(blocks);
    if (!copied.ok())
        return Result!ToolResult(ToolResult.init, copied.error);
    output.content = copied.value;
    if (structured.length)
    {
        const copiedFields = arena.copyIn(structured);
        if (!copiedFields.ok())
            return Result!ToolResult(ToolResult.init, copiedFields.error);
        output.structuredContent = copiedFields.value;
    }
    return Result!ToolResult(output);
}

private Range responseHeader(scope const(ubyte)[] bytes, string name) pure nothrow @nogc
{
    Range selected;
    size_t start;
    while (start < bytes.length)
    {
        size_t end = start;
        while (end < bytes.length && bytes[end] != '\n')
            ++end;
        auto text = bytes[start .. end];
        if (text.length && text[$ - 1] == '\r')
            text = text[0 .. $ - 1];
        if (text.length > 5 && text[0 .. 5] == cast(const(ubyte)[]) "HTTP/")
            selected = Range.init;
        size_t colon;
        while (colon < text.length && text[colon] != ':')
            ++colon;
        if (colon < text.length && equalName(cast(const(char)[]) text[0 .. colon], name))
        {
            if (selected.present())
                return Range.init;
            const value = fieldValue(text, colon + 1);
            selected = Range(start + value.offset, value.length);
        }
        start = end + 1;
    }
    return selected;
}

private Range fieldValue(scope const(ubyte)[] text, size_t value) pure nothrow @nogc
{
    while (value < text.length && (text[value] == ' ' || text[value] == '\t'))
        ++value;
    size_t end = text.length;
    while (end > value && (text[end - 1] == ' ' || text[end - 1] == '\t'))
        --end;
    return Range(value, end - value);
}

private bool validSession(scope const(ubyte)[] session) pure nothrow @nogc
{
    if (session.length == 0 || session.length > 256)
        return false;
    foreach (character; session)
    {
        if (character < 0x21 || character > 0x7e)
            return false;
    }
    return true;
}

private bool validOptions(scope const ref McpClientOptions options) pure nothrow @nogc
{
    enum maximumAuthorizationBytes = 4_096;
    if (options.revision > ProtocolRevision.legacy20251125 || options.authorization.length > maximumAuthorizationBytes)
        return false;
    if (options.maxMessageBytes < 1024 || options.maxMessageBytes > maxMessage || options.maxInputRounds > 8)
        return false;
    foreach (character; options.authorization)
    {
        if (character < ' ' || character == 127)
            return false;
    }
    return true;
}

private bool validEndpoint(scope const(char)[] endpoint) pure nothrow @nogc
{
    if (endpoint.length > 4096)
        return false;
    const https = endpoint.length > 8 && endpoint[0 .. 8] == "https://";
    if (!https && !(endpoint.length > 7 && endpoint[0 .. 7] == "http://"))
        return false;
    if (!validEndpointBytes(endpoint))
        return false;
    const authority = endpoint[https ? 8 : 7 .. $];
    const size = authorityLength(authority);
    return size > 0 && (https || localAuthority(authority[0 .. size]));
}

private size_t authorityLength(scope const(char)[] endpoint) pure nothrow @nogc
{
    size_t end;
    while (end < endpoint.length && endpoint[end] != '/' && endpoint[end] != '?')
    {
        if (endpoint[end] == '@')
            return 0;
        ++end;
    }
    return end;
}

private bool validEndpointBytes(scope const(char)[] endpoint) pure nothrow @nogc
{
    foreach (character; endpoint)
    {
        if (character <= ' ' || character == 127 || character == '#' || character == '\\')
            return false;
    }
    return true;
}

private bool localAuthority(scope const(char)[] authority) pure nothrow @nogc
{
    if (authority.length >= 9 && authority[0 .. 9] == "127.0.0.1")
        return validLoopbackPort(authority[9 .. $]);
    if (authority.length >= 5 && authority[0 .. 5] == "[::1]")
        return validLoopbackPort(authority[5 .. $]);
    return false;
}

private bool validLoopbackPort(scope const(char)[] suffix) pure nothrow @nogc
{
    if (suffix.length == 0)
        return true;
    if (suffix[0] != ':' || suffix.length < 2 || suffix.length > 6)
        return false;
    foreach (character; suffix[1 .. $])
    {
        if (character < '0' || character > '9')
            return false;
    }
    return true;
}
