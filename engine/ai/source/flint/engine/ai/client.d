/// Owner-confined chat client with bounded streams and explicit retry policy.
module flint.engine.ai.client;

import core.atomic : atomicLoad, atomicOp, cas;
import flint.engine.ai.events : EventRun, protocolError;
import flint.engine.ai.providers.anthropic : AnthropicStream;
import flint.engine.ai.providers.gemini : GeminiStream;
import flint.engine.ai.providers.openai : responsesEvent;
import flint.engine.ai.providers.openrouter : RouterChatStream, routerResponsesEvent;
import flint.engine.ai.request : Wire, encodeRequest, wireFor;
import flint.engine.ai.sse : SseParser;
import flint.engine.ai.tool_calls : ArgumentBlock, maxArgumentBlocks;
import flint.engine.ai.types : AiOptions, ChatEvent, ChatMessage, ChatOptions, EventConsumer,
    EventKind, FailureKind, Provider, RouterDialect;
import flint.arena : Error, Arena = RequestArena, Status;
import flint.conc : Context, Deadline, fillSecureRandom;
import flint.conc.wait : waitUntil;
import flint.engine.http : ClientOptions, HttpClient, HttpMethod, HttpRequestView, HttpStreamField;

@safe:

private enum byteLimit = 1024 * 1024;
private shared ulong ownerSerial;
private ulong ownerGeneration;

/// A reusable provider client. Copies share an owner, connection limits and lifecycle.
struct ChatClient
{
    private State state;

    /// Prepare bounded request storage and a verified TLS connection pool.
    Error open(AiOptions options)
    {
        if (state !is null && state.opened)
            return Error(Status.conflict, "chat client already open");
        if (!approved(options))
            return Error(Status.invalidArgument, "invalid provider, endpoint, credential or chat capacity");
        auto created = new State(options);
        ClientOptions transport;
        transport.maxConnections = options.maxConcurrentRequests;
        transport.maxConnectionsPerOrigin = options.maxConcurrentRequests;
        transport.maxResponseBytes = 16 * byteLimit;
        transport.caBundle = options.caBundle;
        const error = created.transport.open(transport);
        if (error.code == Status.ok)
        {
            created.opened = true;
            state = created;
        }
        return error;
    }

    /// Submit provider-native streaming input and deliver each security-checked event once.
    Error stream(scope const(ChatMessage)[] messages, ChatOptions options, ref scope Arena arena,
            ref Context context, scope EventConsumer consume) nothrow @nogc
    {
        auto client = state;
        if (client is null)
            return Error(Status.conflict, "chat client is closed");
        const owned = client.claim();
        if (owned.code != Status.ok)
            return owned;
        if (!client.opened)
            return Error(Status.conflict, "chat client is closed");
        if (consume is null || options.maxEventBytes == 0 || options.maxEventBytes > client.eventBytes)
            return Error(Status.invalidArgument, "chat consumer or requested event capacity is invalid");
        const live = context.check();
        if (live.code != Status.ok)
            return live;
        auto workspace = client.acquire();
        if (workspace is null)
            return Error(Status.resourceExhausted, "chat maximum concurrent requests reached");
        scope (exit)
            workspace.used = false;
        const available = workspace.target(client.endpoint, client.wire, options.model);
        if (available == 0)
            return Error(Status.invalidArgument, "invalid Gemini model URL component");
        const encoded = encodeRequest(client.wire, messages, options, arena, workspace.upload);
        if (!encoded.ok)
            return encoded.error;
        return client.exchange(workspace, encoded.value, available, options, context, consume);
    }

    /// Close on the owning thread after every admitted request has settled.
    Error close() nothrow @nogc
    {
        auto client = state;
        if (client is null)
            return Error.init;
        const owned = client.claim();
        if (owned.code != Status.ok)
            return owned;
        foreach (workspace; client.slots)
            if (workspace.used)
                return Error(Status.conflict, "chat client has live requests");
        const result = client.transport.close();
        if (result.code == Status.ok)
        {
            client.opened = false;
            client.slots = null;
            state = null;
        }
        return result;
    }
}

private final class Workspace
{
    bool used;
    char[] url;
    char[] identity;
    HttpStreamField[5] fields;
    uint fieldCount;
    ubyte[] upload;
    ubyte[] line;
    ubyte[] data;
    ubyte[] eventStorage;
    ArgumentBlock[] blocks;

    this(AiOptions options, string authorization, size_t urlLength)
    {
        url = new char[urlLength + 300];
        identity = new char[32];
        upload = new ubyte[options.maxRequestBytes];
        line = new ubyte[options.maxBufferedEventBytes + 9];
        data = new ubyte[options.maxBufferedEventBytes];
        eventStorage = new ubyte[byteLimit + options.maxBufferedEventBytes + 4096];
        blocks = new ArgumentBlock[maxArgumentBlocks];
        fields[fieldCount++] = HttpStreamField("Content-Type", "application/json");
        fields[fieldCount++] = HttpStreamField("Accept", "text/event-stream");
        if (options.provider == Provider.anthropic)
        {
            fields[fieldCount++] = HttpStreamField("X-Api-Key", options.apiKey);
            fields[fieldCount++] = HttpStreamField("Anthropic-Version", options.apiVersion);
        }
        else if (options.provider == Provider.gemini)
            fields[fieldCount++] = HttpStreamField("X-Goog-Api-Key", options.apiKey);
        else
            fields[fieldCount++] = HttpStreamField("Authorization", authorization);
        fields[fieldCount++] = HttpStreamField("X-Flint-Request-Id", identity);
    }

    size_t target(string endpoint, Wire wire, string model) scope nothrow @nogc
    {
        url[0 .. endpoint.length] = endpoint;
        if (wire != Wire.generateContent)
            return endpoint.length;
        if (!model.length || model.length > 256)
            return 0;
        foreach (character; model)
            if (!asciiAlphaNumeric(character) && character != '_' && character != '-' && character != '.')
                return 0;
        const end = endpoint.length + model.length;
        url[endpoint.length .. end] = model;
        enum suffix = ":streamGenerateContent?alt=sse";
        url[end .. end + suffix.length] = suffix;
        return end + suffix.length;
    }

    Error identify() scope nothrow @nogc
    {
        ubyte[16] random;
        const ready = fillSecureRandom(random[]);
        if (ready.code != Status.ok)
            return ready;
        enum hex = "0123456789abcdef";
        foreach (index, value; random)
        {
            identity[index * 2] = hex[value >> 4];
            identity[index * 2 + 1] = hex[value & 15];
        }
        return Error.init;
    }
}

private final class State
{
    private shared ulong owner;
    bool opened;
    HttpClient transport;
    Wire wire;
    size_t eventBytes;
    string endpoint;
    Workspace[] slots;

    this(AiOptions options)
    {
        wire = wireFor(options);
        endpoint = route(options, wire);
        eventBytes = options.maxBufferedEventBytes;
        const authorization = wire == Wire.messages || wire == Wire.generateContent ? null : "Bearer " ~ options.apiKey;
        slots = new Workspace[options.maxConcurrentRequests];
        foreach (ref workspace; slots)
            workspace = new Workspace(options, authorization, endpoint.length);
    }

    Error claim() scope nothrow @nogc
    {
        if (ownerGeneration == 0)
            ownerGeneration = atomicOp!"+="(ownerSerial, 1UL);
        const observed = atomicLoad(owner);
        if (ownerGeneration == 0 || (observed != ownerGeneration && !cas(&owner, 0UL, ownerGeneration)))
            return Error(Status.conflict, "chat client belongs to another owner thread");
        return Error.init;
    }

    Workspace acquire() scope nothrow @nogc
    {
        foreach (workspace; slots)
            if (!workspace.used)
            {
                workspace.used = true;
                return workspace;
            }
        return null;
    }

    Error exchange(Workspace workspace, size_t uploadSize, size_t urlSize,
            scope const ref ChatOptions options, ref Context context, scope EventConsumer consume) scope nothrow @nogc
    {
        auto eventArena = Arena(workspace.eventStorage);
        auto parser = SseParser(workspace.line[0 .. options.maxEventBytes + 9],
                workspace.data[0 .. options.maxEventBytes]);
        auto run = EventRun(workspace.blocks);
        StreamAdapter adapter;
        adapter.wire = wire;
        bool rejected;
        scope EventConsumer deliver = (ref ChatEvent event, ref scope Arena arena) @safe nothrow @nogc {
            const outcome = consume(event, arena);
            rejected |= outcome.code != Status.ok;
            return Error(outcome.code, outcome.message, outcome.offset);
        };
        scope HttpRequestView request;
        request.method = HttpMethod.post;
        request.url = workspace.url[0 .. urlSize];
        request.body = workspace.upload[0 .. uploadSize];
        request.headers = workspace.fields[0 .. workspace.fieldCount];
        request.successBodyOnly = true;
        for (uint attempt;; ++attempt)
        {
            const identity = workspace.identify();
            if (identity.code != Status.ok)
                return identity;
            const response = transport.streamView(request, eventArena, context, (scope const(ubyte)[] chunk) {
                return adapter.parse(chunk, parser, eventArena, run, context, deliver);
            });
            if (!response.ok)
                return rejected || run.terminal ? response.error : failTransfer(response.error,
                        eventArena, run, deliver);
            if (successful(response.value))
                break;
            if (!retryable(response.value) || attempt == options.maxPrestreamRetries)
                return failHttp(response.value, eventArena, run, deliver);
            const delayed = retryDelay(attempt, context);
            if (delayed.code != Status.ok)
                return failTransfer(delayed, eventArena, run, deliver);
        }
        return adapter.complete(parser, eventArena, run, deliver);
    }
}

private struct StreamAdapter
{
    Wire wire;
    AnthropicStream anthropic;
    GeminiStream gemini;
    RouterChatStream router;

    Error parse(scope const(ubyte)[] chunk, ref scope SseParser parser, ref scope Arena arena,
            ref scope EventRun run, ref Context context, scope EventConsumer consume) scope nothrow @nogc
    {
        return parser.feed(chunk, (scope const(char)[] name, scope const(ubyte)[] json) {
            const live = context.check();
            if (live.code != Status.ok)
                return Error(live.code, live.message, live.offset);
            if (run.terminal)
                return Error.init;
            if (arena.reset() != Status.ok)
                return Error(Status.conflict, "event arena is borrowed");
            return dispatch(name, json, run, arena, consume);
        });
    }

    private Error dispatch(scope const(char)[] name, scope const(ubyte)[] json, ref scope EventRun run,
            ref scope Arena arena, scope EventConsumer consume) scope nothrow @nogc
    {
        final switch (wire)
        {
        case Wire.responses:
            return responsesEvent(name, json, run, arena, consume);
        case Wire.messages:
            return anthropic.event(name, json, run, arena, consume);
        case Wire.generateContent:
            return gemini.event(name, json, run, arena, consume);
        case Wire.routerResponses:
            return routerResponsesEvent(name, json, run, arena, consume);
        case Wire.routerChat:
            return router.event(name, json, run, arena, consume);
        }
    }

    Error complete(ref scope const SseParser parser, ref scope Arena arena, ref scope EventRun run,
            scope EventConsumer consume) scope nothrow @nogc
    {
        if (run.terminal)
            return Error.init;
        const complete = parser.finish();
        if (complete.code != Status.ok || (wire != Wire.generateContent || !gemini.finished))
            return run.fail(FailureKind.incomplete, Status.ioError,
                    "provider stream ended before its terminal event", arena, consume);
        return run.success(arena, consume);
    }
}

private bool retryable(ushort status) pure nothrow @nogc
{
    return status == 429 || status == 502 || status == 503 || status == 529;
}

private bool successful(ushort status) pure nothrow @nogc
{
    return status >= 200 && status < 300;
}

private Error retryDelay(uint attempt, ref Context context) nothrow @nogc
{
    const target = Deadline.afterMillis(20UL << attempt).monotonicNanoseconds;
    const deadline = context.deadline().monotonicNanoseconds;
    const until = target < deadline ? target : deadline;
    for (;;)
    {
        const live = context.check();
        if (live.code != Status.ok)
            return live;
        if (Deadline.afterMillis(0).monotonicNanoseconds >= until)
            return Error.init;
        const next = Deadline.afterMillis(5).monotonicNanoseconds;
        const waited = waitUntil(Deadline(next < until ? next : until));
        if (waited.code != Status.ok)
            return waited;
    }
}

// dfmt off
private Error failTransfer(Error outcome, ref scope Arena arena, ref scope EventRun run,
        scope EventConsumer consume) nothrow @nogc
{
    if (arena.reset() != Status.ok)
        return Error(Status.conflict, "event arena is borrowed");
    const cancelled = outcome.code == Status.cancelled || outcome.code == Status.timedOut;
    const category = cancelled ? FailureKind.cancelled : (outcome.code == Status.ioError
            ? FailureKind.incomplete : FailureKind.provider);
    return run.fail(category, outcome.code, outcome.message, arena, consume);
}
// dfmt on

// dfmt off
private Error failHttp(ushort code, ref scope Arena arena, ref scope EventRun run,
        scope EventConsumer send) nothrow @nogc
{
    if (code == 401 || code == 403)
        return run.fail(FailureKind.provider, Status.permissionDenied,
                "provider denied the chat request", arena, send);
    if (code == 429)
        return run.fail(FailureKind.provider, Status.resourceExhausted, "provider rate limit exhausted", arena, send);
    if (code == 400 || code == 404 || code == 422)
        return run.fail(FailureKind.provider, Status.invalidArgument,
                "provider rejected the chat request", arena, send);
    return run.fail(FailureKind.provider, Status.unavailable, "provider did not accept the chat stream", arena, send);
}
// dfmt on

private bool approved(scope const ref AiOptions options) pure nothrow @nogc
{
    if (options.provider > Provider.openRouter || options.routerDialect > RouterDialect.chatCompletions
            || (options.provider != Provider.openRouter && options.routerDialect != RouterDialect.responses)
            || !options.maxConcurrentRequests || options.maxConcurrentRequests > 32
            || !options.maxBufferedEventBytes || options.maxBufferedEventBytes > byteLimit
            || !options.maxRequestBytes || options.maxRequestBytes > byteLimit || !validEndpoint(options.baseUrl,
                options.allowLoopbackCleartext) || !visible(options.apiKey, 4096))
        return false;
    if (options.provider == Provider.anthropic)
        return visible(options.apiVersion, 64);
    if (options.provider == Provider.gemini)
        return options.apiVersion == "v1" || options.apiVersion == "v1beta";
    return options.apiVersion.length == 0;
}

private bool visible(scope const(char)[] value, size_t limit) pure nothrow @nogc
{
    if (value.length == 0 || value.length > limit)
        return false;
    foreach (character; value)
        if (character <= ' ' || character >= 127)
            return false;
    return true;
}

private bool validEndpoint(string value, bool allowLoopback) pure nothrow @nogc
{
    if (!visible(value, 2048))
        return false;
    const tls = value.length >= 8 && value[0 .. 8] == "https://";
    const plain = value.length >= 7 && value[0 .. 7] == "http://";
    if (!tls && (!plain || !allowLoopback))
        return false;
    const prefix = tls ? 8 : 7;
    const rest = value[prefix .. $];
    const end = authorityBytes(rest);
    if (end == 0)
        return false;
    const hostPort = rest[0 .. end];
    return tls || numericLoopback(hostPort, "127.0.0.1") || numericLoopback(hostPort, "[::1]");
}

private size_t authorityBytes(scope const(char)[] endpoint) pure nothrow @nogc
{
    size_t end = endpoint.length;
    foreach (index, character; endpoint)
    {
        if (character == '@' || character == '?' || character == '#' || character == '\\' || character == '%')
            return 0;
        if (character == '/' && end == endpoint.length)
            end = index;
    }
    return end;
}

private bool numericLoopback(scope const(char)[] authority, string host) pure nothrow @nogc
{
    if (authority == host)
        return true;
    if (authority.length <= host.length + 1 || authority[0 .. host.length] != host || authority[host.length] != ':')
        return false;
    foreach (character; authority[host.length + 1 .. $])
        if (character < '0' || character > '9')
            return false;
    return true;
}

private bool asciiAlphaNumeric(char character) pure nothrow @nogc
{
    return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')
        || (character >= '0' && character <= '9');
}

private string route(scope const ref AiOptions options, Wire wire)
{
    string base = options.baseUrl;
    while (base[$ - 1] == '/')
        base = base[0 .. $ - 1];
    final switch (wire)
    {
    case Wire.responses:
        return base ~ "/v1/responses";
    case Wire.messages:
        return base ~ "/v1/messages";
    case Wire.generateContent:
        return base ~ "/" ~ options.apiVersion ~ "/models/";
    case Wire.routerResponses:
        return base ~ "/api/v1/responses";
    case Wire.routerChat:
        return base ~ "/api/v1/chat/completions";
    }
}
