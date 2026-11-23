/// MCP endpoint over the bounded Web streaming route.
module flint.engine.mcp.http;

import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.engine.mcp.jsonrpc : Identity;
import flint.engine.mcp.operations : Operations, cancellationRequest;
import flint.engine.mcp.modern : modernRevision;
import flint.engine.mcp.legacy : legacyRevision;
import flint.engine.mcp.protocol : Headers, Protocol, Reply;
import flint.engine.mcp.types : McpOptions;
import flint.engine.web : Method, Request, RequestContext, Response, Server, ServerOptions,
    StreamField, StreamMode, StreamRoute, StreamToken;

@safe:
package(flint.engine.mcp):

final class HttpEndpoint
{
    private Server website;
    private Operations operations;
    private McpOptions limits;

    this(Protocol protocol, McpOptions options)
    {
        operations = new Operations(protocol, options.maxMessageBytes, options.maxInFlight);
        limits = options;
    }

    Error open()
    {
        ServerOptions web;
        web.port = limits.port;
        web.address = limits.address;
        web.maxStreamingRequestBytes = limits.maxMessageBytes;
        web.maxConnectionsPerCore = limits.maxInFlight + 2;
        web.maxStreamsPerConnection = limits.maxInFlight;
        web.tlsCertificateFile = limits.tlsCertificateFile;
        web.tlsPrivateKeyFile = limits.tlsPrivateKeyFile;
        const started = website.start(web);
        if (started.code != Status.ok)
            return started;
        if (!website.isLoopbackListener() && limits.authorization is null)
        {
            abortStartup();
            return Error(Status.permissionDenied, "external MCP listener requires authorization");
        }

        const postRoute = website.routeStream(StreamRoute(Method.post, limits.path, StreamMode.response, &post));
        const getRoute = website.route(Method.get, limits.path, &get);
        const deleteRoute = website.route(Method.delete_, limits.path, &remove);
        if (postRoute.code != Status.ok || getRoute.code != Status.ok || deleteRoute.code != Status.ok)
        {
            abortStartup();
            return Error(Status.invalidArgument, "unable to register MCP endpoint");
        }
        const prepared = operations.open();
        if (prepared.code != Status.ok)
            abortStartup();
        return prepared;
    }

    private void abortStartup() nothrow @nogc
    {
        website.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    }

    Error run(ref Context context) nothrow @nogc
    {
        for (;;)
        {
            const current = website.poll(context);
            if (current.code != Status.ok)
                return current;
        }
    }

    Error close(ref Context context) nothrow @nogc
    {
        const deadline = context.withDeadline(Deadline.afterMillis(5_000));
        const stopped = website.shutdown(deadline.deadline().monotonicNanoseconds);
        if (stopped.code == Status.timedOut || stopped.code == Status.conflict)
            return stopped;
        const released = operations.close(context);
        return released.code == Status.ok ? stopped : released;
    }

    private bool authorized(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        scope Field!(16_384) origin;
        if (!origin.load(request, context, "origin"))
            return false;
        if (origin.present)
        {
            bool allowed;
            foreach (candidate; limits.allowedOrigins)
            {
                if (origin.value() == candidate)
                {
                    allowed = true;
                    break;
                }
            }
            if (!allowed)
                return false;
        }
        return limits.authorization is null || limits.authorization(request, context);
    }

    private Result!Response get(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        return Result!Response(Response(authorized(request, context) ? 405 : 403));
    }

    private Result!Response remove(ref scope Request request, ref scope RequestContext context) nothrow @nogc
    {
        if (!authorized(request, context))
            return Result!Response(Response(403));
        scope Field!64 release;
        scope Field!64 session;
        if (!release.load(request, context, "mcp-protocol-version") || !session.load(request,
                context, "mcp-session-id"))
            return Result!Response(Response(400));
        if (release.value() != legacyRevision || !session.present)
            return Result!Response(Response(405));
        scope const headers = Headers(true, false, release.value(), null, null, session.value(), true);
        const queued = operations.submit(null, headers, context.cancellation, true);
        if (!queued.ok())
            return Result!Response(Response(503));
        const waited = waitFor(queued.value, context.cancellation);
        if (!waited.ok())
        {
            operations.detach(queued.value, true);
            return Result!Response(Response.init, waited.error);
        }
        ushort status;
        const result = operations.consume(queued.value, (scope const ref Reply reply,
                scope const(ubyte)[]) @safe nothrow @nogc { status = reply.status; return Error.init; });
        return Result!Response(Response(status), result);
    }

    nothrow @nogc private Error post(ref scope Request request, ref scope RequestContext context,
            scope StreamToken stream)
    {
        if (!authorized(request, context))
            return empty(stream, 403, context.cancellation);
        const media = negotiateResponse(request, context);
        if (media.rejection)
            return empty(stream, media.rejection, context.cancellation);
        scope Inbound incoming;
        incoming.load(request, context);
        const admitted = queueEntity(request, context, incoming);
        if (admitted.immediate)
            return empty(stream, admitted.immediate, context.cancellation);
        if (admitted.error.code != Status.ok)
            return admitted.error;

        const events = media.events && (!media.json || incoming.method.value() == "tools/call");
        return finishEntity(stream, context.cancellation, admitted.position, events, incoming.legacy());
    }

    private Admission queueEntity(ref scope Request request, ref scope RequestContext context,
            scope const ref Inbound incoming) nothrow @nogc
    {
        const entity = request.body();
        if (!entity.ok())
            return Admission(0, 0, entity.error);
        scope const headers = incoming.view();
        const legacy = incoming.legacy();
        Context parent;
        if (!legacy)
            parent = context.cancellation;
        Admission admitted;
        const borrowed = context.arena.read(entity.value, (scope const(ubyte)[] message) @safe nothrow @nogc {
            if (acceptCancellation(message, incoming))
            {
                admitted.immediate = 202;
                return;
            }
            const submitted = operations.submit(message, headers, parent, legacy);
            admitted.position = submitted.value;
            if (!submitted.ok())
                admitted.immediate = 503;
        });
        if (borrowed != Status.ok)
            admitted.error = Error(borrowed, "MCP HTTP request body lifetime ended");
        return admitted;
    }

    private bool acceptCancellation(scope const(ubyte)[] message, scope const ref Inbound incoming) nothrow @nogc
    {
        if (incoming.invalid || !incoming.legacy() || incoming.release.value() != legacyRevision
                || !incoming.session.present)
            return false;
        Identity id;
        if (!cancellationRequest(message, limits.maxMessageBytes, id))
            return false;
        if (id.present)
            operations.cancel(id, incoming.session.value());
        return true;
    }

    private Error finishEntity(scope StreamToken stream, ref scope Context context, uint position,
            bool events, bool legacy) nothrow @nogc
    {
        const waited = waitFor(position, context, stream, events && !legacy);
        if (!waited.ok())
        {
            operations.detach(position, !legacy);
            return waited.error;
        }
        const started = waited.value;
        return operations.consume(position, (scope const ref Reply reply, scope const(ubyte)[] payload) {

            return send(stream, reply, payload, context, events && (started || reply.status == 200), started);
        });
    }

    private Result!bool waitFor(uint position, ref scope Context context,
            scope StreamToken stream = StreamToken.init, bool beginEvents = false) nothrow @nogc
    {
        bool started;
        auto heartbeatAt = Deadline.afterMillis(10_000);
        for (;;)
        {
            const checked = context.check();
            if (checked.code != Status.ok)
                return Result!bool(false, checked);
            if (operations.complete(position))
                return Result!bool(started);
            if (beginEvents && !started && operations.entered(position))
            {
                const begun = stream.begin(200, [
                    StreamField("content-type", "text/event-stream"),
                    StreamField("x-accel-buffering", "no")
                ], context);
                if (begun.code != Status.ok)
                    return Result!bool(started, begun);
                started = true;
                heartbeatAt = Deadline.afterMillis(0);
            }
            if (started && Deadline.afterMillis(0).monotonicNanoseconds >= heartbeatAt.monotonicNanoseconds)
            {
                const heartbeat = stream.send(cast(const(ubyte)[]) ": working\n\n", context);
                if (heartbeat.code != Status.ok)
                    return Result!bool(started, heartbeat);
                heartbeatAt = Deadline.afterMillis(10_000);
            }
            const waited = waitUntil(Deadline(Deadline.afterMillis(0).monotonicNanoseconds + 100_000));
            if (waited.code != Status.ok)
                return Result!bool(started, waited);
        }
    }
}

private struct Admission
{
    uint position;
    ushort immediate;
    Error error;
}

private struct Inbound
{
    Field!64 release;
    Field!128 method;
    Field!1536 routeName;
    Field!64 session;
    bool invalid;

    void load(ref scope Request request, ref scope RequestContext context) scope nothrow @nogc
    {
        invalid = !release.load(request, context, "mcp-protocol-version") || !method.load(request,
                context, "mcp-method") || !routeName.load(request, context, "mcp-name")
            || !session.load(request, context, "mcp-session-id");
    }

    Headers view() const return pure nothrow @nogc
    {
        return Headers(true, invalid, release.value(), method.value(), routeName.value(), session.value());
    }

    bool legacy() const scope pure nothrow @nogc
    {
        return release.value() != modernRevision && !method.present;
    }
}

private struct ResponseMedia
{
    bool json;
    bool events;
    ushort rejection;
}

private ResponseMedia negotiateResponse(ref scope Request request, ref scope RequestContext context) nothrow @nogc
{
    scope Field!256 media;
    if (!media.load(request, context, "content-type") || !media.present
            || !includes(media.value(), "application/json", ';'))
        return ResponseMedia(false, false, 415);
    scope Field!2048 accept;
    if (!accept.load(request, context, "accept"))
        return ResponseMedia(false, false, 406);

    const value = accept.value();
    const json = !accept.present || includes(value, "application/json") || includes(value, "*/*");
    const events = includes(value, "text/event-stream");
    return ResponseMedia(json, events, json || events ? 0 : 406);
}

private struct Field(size_t capacity)
{
    char[capacity] storage;
    size_t length;
    bool present;

    const(char)[] value() const return pure nothrow @nogc
    {
        return storage[0 .. length];
    }

    bool load(ref scope Request request, ref scope RequestContext context, string name) scope nothrow @nogc
    {
        const matches = request.headerCount(name);
        if (!matches)
            return true;
        present = true;
        if (matches != 1)
            return false;
        const field = request.header(name);
        if (!field.ok() || field.value.length() > storage.length)
            return false;
        return context.arena.read(field.value, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
            storage[0 .. bytes.length] = cast(const(char)[]) bytes;
            length = bytes.length;
        }) == Status.ok;
    }
}

private Error empty(scope StreamToken stream, ushort status, ref scope Context context) nothrow @nogc
{
    const started = stream.begin(status, [], context);
    return started.code == Status.ok ? stream.finish([], context) : started;
}

private Error send(scope StreamToken stream, scope const ref Reply response, scope const(ubyte)[] bytes,
        ref scope Context context, bool events, bool began) nothrow @nogc
{
    if (response.error.code != Status.ok)
        return began || response.error.code == Status.cancelled ? stream.cancel() : empty(stream, 500, context);
    if (!bytes.length)
        return began ? stream.finish([], context) : empty(stream, response.status, context);

    if (!began)
    {
        const started = beginResponse(stream, response, context, events);
        if (started.code != Status.ok)
            return started;
    }
    const sent = events ? sendEvent(stream, bytes, context) : stream.send(bytes, context);
    return sent.code == Status.ok ? stream.finish([], context) : sent;
}

private Error beginResponse(scope StreamToken stream, scope const ref Reply response,
        ref scope Context context, bool events) nothrow @nogc
{
    const kind = StreamField("content-type", events ? "text/event-stream" : "application/json");
    const flushing = StreamField("x-accel-buffering", "no");
    if (response.mintSession)
    {
        const session = response.session;
        scope const field = StreamField("mcp-session-id", session.text[]);
        if (events)
            return stream.begin(response.status, [kind, field, flushing], context);
        return stream.begin(response.status, [kind, field], context);
    }
    if (events)
        return stream.begin(response.status, [kind, flushing], context);
    return stream.begin(response.status, [kind], context);
}

private Error sendEvent(scope StreamToken stream, scope const(ubyte)[] bytes, ref scope Context context) nothrow @nogc
{
    // Normalize physical JSON whitespace into consecutive SSE data fields.
    size_t first;
    foreach (index, byteValue; bytes)
    {
        if (byteValue == '\r' || byteValue == '\n')
        {
            const sent = sendLine(stream, bytes[first .. index], context);
            if (sent.code != Status.ok)
                return sent;
            first = index + 1;
        }
    }
    const sent = sendLine(stream, bytes[first .. $], context);
    return sent.code == Status.ok ? stream.send(cast(const(ubyte)[]) "\n", context) : sent;
}

private Error sendLine(scope StreamToken stream, scope const(ubyte)[] bytes, ref scope Context context) nothrow @nogc
{
    auto sent = stream.send(cast(const(ubyte)[]) "data: ", context);
    if (sent.code == Status.ok)
        sent = stream.send(bytes, context);
    return sent.code == Status.ok ? stream.send(cast(const(ubyte)[]) "\n", context) : sent;
}

bool includes(scope const(char)[] list, string item, char separator = ',') pure nothrow @nogc
{
    size_t offset;
    while (offset < list.length)
    {
        size_t end = offset;
        while (end < list.length && list[end] != separator)
            ++end;
        auto token = trim(list[offset .. end]);
        size_t parameters;
        while (parameters < token.length && token[parameters] != ';')
            ++parameters;
        if (equalName(trim(token[0 .. parameters]), item))
            return true;
        if (separator == ';' || end == list.length)
            return false;
        offset = end + 1;
    }
    return false;
}

private const(char)[] trim(return scope const(char)[] value) pure nothrow @nogc
{
    while (value.length != 0 && (value[0] == ' ' || value[0] == '\t'))
        value = value[1 .. $];
    while (value.length != 0 && (value[$ - 1] == ' ' || value[$ - 1] == '\t'))
        value = value[0 .. $ - 1];
    return value;
}

bool equalName(scope const(char)[] left, scope const(char)[] right) pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (index, character; left)
    {
        if (lower(character) != lower(right[index]))
            return false;
    }
    return true;
}

private char lower(char value) pure nothrow @nogc
{
    return value >= 'A' && value <= 'Z' ? cast(char)(value + ('a' - 'A')) : value;
}
