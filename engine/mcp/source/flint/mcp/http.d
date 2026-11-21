/// MCP endpoint over the bounded Web streaming route.
module flint.mcp.http;

import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.mcp.jsonrpc : Identity;
import flint.mcp.operations : Operations, cancellationRequest;
import flint.mcp.modern : modernRevision;
import flint.mcp.legacy : legacyRevision;
import flint.mcp.protocol : Headers, Protocol, Reply;
import flint.mcp.types : McpOptions;
import flint.web : Method, Request, RequestContext, Response, Server, ServerOptions, StreamField,
    StreamMode, StreamRoute, StreamToken;

@safe:
package(flint.mcp):

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
        if (waited.code != Status.ok)
        {
            operations.detach(queued.value, true);
            return Result!Response(Response.init, waited);
        }
        ushort status;
        const result = operations.consume(queued.value, (scope const ref Reply reply,
                scope const(ubyte)[] unused) @safe nothrow @nogc {
            status = reply.status;
            return Error.init;
        });
        return Result!Response(Response(status), result);
    }

    private Error post(ref scope Request request, ref scope RequestContext context, scope StreamToken stream) nothrow @nogc
    {
        if (!authorized(request, context))
            return empty(stream, 403, context.cancellation);
        scope Field!256 media;
        scope Field!2048 accept;
        if (!media.load(request, context, "content-type") || !media.present
                || !includes(media.value(), "application/json", ';'))
            return empty(stream, 415, context.cancellation);
        if (!accept.load(request, context, "accept"))
            return empty(stream, 406, context.cancellation);
        const acceptsJson = !accept.present || includes(accept.value(), "application/json")
            || includes(accept.value(), "*/*");
        const acceptsEvents = includes(accept.value(), "text/event-stream");
        if (!acceptsJson && !acceptsEvents)
            return empty(stream, 406, context.cancellation);

        scope Field!64 release;
        scope Field!128 method;
        scope Field!1536 routeName;
        scope Field!64 session;
        const valid = release.load(request, context, "mcp-protocol-version") && method.load(request,
                context, "mcp-method") && routeName.load(request, context, "mcp-name")
            && session.load(request, context, "mcp-session-id");
        scope const headers = Headers(true, !valid, release.value(), method.value(),
                routeName.value(), session.value());
        const legacy = release.value() != modernRevision && !method.present;
        Context detached;
        auto parent = legacy ? detached : context.cancellation;
        Result!uint queued;
        bool notification;
        const entity = request.body();
        if (!entity.ok())
            return entity.error;
        const borrowed = context.arena.read(entity.value, (scope const(ubyte)[] message) @safe nothrow @nogc {
            Identity id;
            if (valid && legacy && release.value() == legacyRevision && session.present
                && cancellationRequest(message, limits.maxMessageBytes, id))
            {
                if (id.present)
                    operations.cancel(id, session.value());
                notification = true;
            }
            else
            {
                const submitted = operations.submit(message, headers, parent, legacy);
                queued.value = submitted.value;
                queued.error.code = submitted.error.code;
            }
        });
        if (borrowed != Status.ok)
            return Error(borrowed, "MCP HTTP request body lifetime ended");
        if (notification)
            return empty(stream, 202, context.cancellation);
        if (!queued.ok())
            return empty(stream, 503, context.cancellation);

        const position = queued.value;
        const events = acceptsEvents && (!acceptsJson || method.value() == "tools/call");
        bool started;
        const waited = waitFor(position, context.cancellation, stream, events && !legacy, started);
        if (waited.code != Status.ok)
        {
            operations.detach(position, !legacy);
            return waited;
        }
        return operations.consume(position, (scope const ref Reply reply, scope const(ubyte)[] bytes) @safe nothrow @nogc {
            return send(stream, reply, bytes, context.cancellation, events && (started || reply.status == 200), started);
        });
    }

    private Error waitFor(uint position, ref scope Context context) nothrow @nogc
    {
        bool started;
        return waitFor(position, context, StreamToken.init, false, started);
    }

    private Error waitFor(uint position, ref scope Context context, scope StreamToken stream,
            bool beginEvents, out bool started) nothrow @nogc
    {
        auto heartbeatAt = Deadline.afterMillis(10_000);
        for (;;)
        {
            const checked = context.check();
            if (checked.code != Status.ok)
                return checked;
            if (operations.complete(position))
                return Error.init;
            if (beginEvents && !started && operations.entered(position))
            {
                const begun = stream.begin(200, [
                    StreamField("content-type", "text/event-stream"),
                    StreamField("x-accel-buffering", "no")
                ], context);
                if (begun.code != Status.ok)
                    return begun;
                started = true;
                heartbeatAt = Deadline.afterMillis(0);
            }
            if (started && Deadline.afterMillis(0).monotonicNanoseconds >= heartbeatAt.monotonicNanoseconds)
            {
                const heartbeat = stream.send(cast(const(ubyte)[]) ": working\n\n", context);
                if (heartbeat.code != Status.ok)
                    return heartbeat;
                heartbeatAt = Deadline.afterMillis(10_000);
            }
            const waited = waitUntil(Deadline(Deadline.afterMillis(0).monotonicNanoseconds + 100_000));
            if (waited.code != Status.ok)
                return waited;
        }
    }
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
