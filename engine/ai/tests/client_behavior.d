module flint.engine.ai.client_behavior;

import flint.engine.ai : AiOptions, ChatClient, ChatEvent, ChatMessage, ChatOptions, EventConsumer,
    EventKind, FailureKind, Provider, Role, RouterDialect;
import flint.arena : Error, RequestArena, Status;
import flint.conc : CancelSource, Context, Deadline;
import std.process : environment;

@safe:

@("provider configuration rejects plaintext and mismatched options")
unittest
{
    ChatClient client;
    AiOptions options;
    options.baseUrl = "http://example.com";
    options.apiKey = "test-key";
    options.allowLoopbackCleartext = true;
    assert(client.open(options).code == Status.invalidArgument);
    options.baseUrl = "https://127.0.0.1";
    options.maxConcurrentRequests = 33;
    assert(client.open(options).code == Status.invalidArgument);
    options.maxConcurrentRequests = 1;
    options.provider = Provider.gemini;
    assert(client.open(options).code == Status.invalidArgument);
    options.apiVersion = "v1beta";
    options.routerDialect = RouterDialect.chatCompletions;
    assert(client.open(options).code == Status.invalidArgument);
}

private struct Observed
{
    uint text, completed, usage;
    FailureKind failure;

    Error receive(ref ChatEvent event, ref scope RequestArena arena) scope nothrow @nogc
    {
        final switch (event.kind)
        {
        case EventKind.textDelta:
            ++text;
            assert(arena.read(event.text, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                    assert(bytes == cast(const(ubyte)[]) "hé");
                }) == Status.ok);
            break;
        case EventKind.completed:
            ++completed;
            break;
        case EventKind.usage:
            ++usage;
            assert(event.inputTokens == 7 && event.outputTokens == 3);
            break;
        case EventKind.failed:
            failure = event.failure;
            break;
        case EventKind.toolDelta:
            assert(0, "loopback text fixture did not ask for a tool");
        }
        return Error.init;
    }
}

@("real transport verifies provider-specific envelopes, prestream retries and cancellation")
unittest
{
    const origin = environment.get("FLINT_AI_TEST_URL", "");
    if (!origin.length)
        return;
    ubyte[4096] memory;
    auto arena = RequestArena(memory[]);
    const seeded = arena.copyIn(cast(const(ubyte)[]) "prompt\n\"quoted\" 🦊");
    assert(seeded.ok);
    const ChatMessage[1] messages = [ChatMessage(Role.user, seeded.value)];
    foreach (provider; [Provider.openAI, Provider.anthropic, Provider.gemini, Provider.openRouter])
        exercise(origin, provider, RouterDialect.responses, messages[], arena);
    exercise(origin, Provider.openRouter, RouterDialect.chatCompletions, messages[], arena);
}

private void exercise(string origin, Provider provider, RouterDialect dialect,
        scope const(ChatMessage)[] messages, ref scope RequestArena arena)
{
    AiOptions configuration;
    configuration.baseUrl = origin;
    configuration.apiKey = "test-key";
    configuration.provider = provider;
    configuration.routerDialect = dialect;
    configuration.allowLoopbackCleartext = true;
    configuration.maxConcurrentRequests = 1;
    configuration.maxBufferedEventBytes = 16_384;
    if (provider == Provider.anthropic)
        configuration.apiVersion = "2023-06-01";
    else if (provider == Provider.gemini)
        configuration.apiVersion = "v1beta";

    ChatClient client;
    const opened = client.open(configuration);
    assert(opened.code == Status.ok, opened.message);
    scope (exit)
        assert(client.close().code == Status.ok);
    ChatOptions chat;
    chat.model = "fixture";
    chat.maxEventBytes = configuration.maxBufferedEventBytes;
    chat.maxOutputTokens = 40;
    chat.temperature = 0.25;
    Context context;
    Observed normal;
    const result = client.stream(messages, chat, arena, context, &normal.receive);
    assert(result.code == Status.ok, result.message);
    assert(normal.text == 1 && normal.completed == 1 && normal.usage == 1 && normal.failure == FailureKind.none);

    Observed rejected;
    chat.model = "rejected";
    chat.maxPrestreamRetries = 0;
    assert(client.stream(messages, chat, arena, context, &rejected.receive).code == Status.resourceExhausted);
    assert(rejected.text == 0 && rejected.completed == 0 && rejected.failure == FailureKind.provider);

    Observed early;
    chat.model = "early";
    assert(client.stream(messages, chat, arena, context, &early.receive).code == Status.ioError);
    assert(early.text == 1 && early.completed == 0 && early.failure == FailureKind.incomplete);

    auto cancellation = CancelSource.create(Context.init, Deadline.afterMillis(3_000));
    assert(cancellation.ok);
    auto cancelled = cancellation.value.context();
    chat.model = "cancel";
    chat.maxPrestreamRetries = 3;
    Observed stopped;
    const aborted = client.stream(messages, chat, arena, cancelled, (ref ChatEvent event,
            ref scope RequestArena output) @safe nothrow @nogc {
        const delivered = stopped.receive(event, output);
        if (event.kind == EventKind.textDelta)
        {
            assert(client.close().code == Status.conflict);
            assert(client.stream(messages, chat, arena, cancelled, &stopped.receive).code == Status.resourceExhausted);
            cancellation.value.cancel();
        }
        return Error(delivered.code, delivered.message, delivered.offset);
    });
    assert(aborted.code == Status.cancelled, aborted.message);
    assert(stopped.text == 1 && stopped.completed == 0 && stopped.failure == FailureKind.cancelled);

    cancelAfterTool(client, messages, chat, arena);

    chat.toolRounds = 9;
    assert(client.stream(messages, chat, arena, context, &rejected.receive).code == Status.resourceExhausted);
    chat.toolRounds = 0;
    chat.maxToolRounds = 9;
    assert(client.stream(messages, chat, arena, context, &rejected.receive).code == Status.resourceExhausted);
}

/// cancel_no_replay after a tool side effect: the peer counts exactly one "toolcancel" POST.
private void cancelAfterTool(ref ChatClient client, scope const(ChatMessage)[] messages,
        ChatOptions chat, ref scope RequestArena arena)
{
    auto toolCancellation = CancelSource.create(Context.init, Deadline.afterMillis(3_000));
    assert(toolCancellation.ok);
    auto toolContext = toolCancellation.value.context();
    chat.model = "toolcancel";
    uint tools, completions;
    FailureKind toolFailure;
    const toolAborted = client.stream(messages, chat, arena, toolContext, (ref ChatEvent event,
            ref scope RequestArena output) @safe nothrow @nogc {
        if (event.kind == EventKind.toolDelta)
        {
            ++tools;
            assert(output.read(event.text, (scope const(ubyte)[] bytes) @safe nothrow @nogc {
                    assert(bytes == cast(const(ubyte)[]) `{"a":1}`);
                }) == Status.ok);
            toolCancellation.value.cancel();
        }
        else if (event.kind == EventKind.completed)
            ++completions;
        else if (event.kind == EventKind.failed)
            toolFailure = event.failure;
        return Error.init;
    });
    assert(toolAborted.code == Status.cancelled, toolAborted.message);
    assert(tools == 1 && completions == 0 && toolFailure == FailureKind.cancelled);

}

@("client_state: closed and stale copies refuse streams without a network request")
unittest
{
    AiOptions options;
    options.baseUrl = "http://127.0.0.1:9";
    options.apiKey = "test-key";
    options.allowLoopbackCleartext = true;
    options.maxConcurrentRequests = 32;
    options.maxBufferedEventBytes = 4096;
    options.maxRequestBytes = 4096;
    ChatClient client;
    assert(client.open(options).code == Status.ok);
    assert(client.open(options).code == Status.conflict);
    ubyte[1024] memory;
    auto arena = RequestArena(memory[]);
    const seeded = arena.copyIn(cast(const(ubyte)[]) "prompt");
    const ChatMessage[1] messages = [ChatMessage(Role.user, seeded.value)];
    ChatOptions chat;
    chat.model = "m";
    chat.maxEventBytes = 4096;
    uint events;
    scope EventConsumer count = (ref ChatEvent, ref scope RequestArena) @safe nothrow @nogc {
        ++events;
        return Error.init;
    };
    Context context;
    // Limits fail before a request leaves: oversized event capacity, null consumer, empty model.
    chat.maxEventBytes = 4097;
    assert(client.stream(messages, chat, arena, context, count).code == Status.invalidArgument);
    chat.maxEventBytes = 4096;
    assert(client.stream(messages, chat, arena, context, null).code == Status.invalidArgument);
    chat.model = null;
    assert(client.stream(messages, chat, arena, context, count).code == Status.invalidArgument);
    chat.model = "m";
    const empty = client.stream(null, chat, arena, context, count);
    assert(empty.code == Status.resourceExhausted, empty.message);
    auto source = CancelSource.create(Context.init, Deadline.afterMillis(60_000));
    auto cancelled = source.value.context();
    source.value.cancel();
    assert(client.stream(messages, chat, arena, cancelled, count).code == Status.cancelled);
    assert(events == 0);

    auto copy = client;
    assert(client.close().code == Status.ok);
    assert(client.close().code == Status.ok);
    assert(client.stream(messages, chat, arena, context, count).code == Status.conflict);
    assert(copy.stream(messages, chat, arena, context, count).code == Status.conflict);
    assert(client.open(options).code == Status.ok);
    assert(copy.stream(messages, chat, arena, context, count).code == Status.conflict);
    assert(client.close().code == Status.ok);
    assert(events == 0);
}

@("regression: default ChatOptions encode a request because temperature defaults to 0, not NaN")
unittest
{
    import flint.engine.ai.request : Wire, encodeRequest;

    ChatOptions options;
    assert(options.temperature == 0);
    options.model = "m";
    ubyte[256] memory;
    auto arena = RequestArena(memory[]);
    const content = arena.copyIn(cast(const(ubyte)[]) "hi");
    const ChatMessage[1] messages = [ChatMessage(Role.user, content.value)];
    ubyte[512] upload;
    immutable Wire[5] wires = [
        Wire.responses, Wire.messages, Wire.generateContent, Wire.routerResponses, Wire.routerChat
    ];
    foreach (wire; wires)
    {
        const encoded = encodeRequest(wire, messages[], options, arena, upload[]);
        assert(encoded.ok, encoded.error.message);
        const json = cast(const(char)[]) upload[0 .. encoded.value];
        enum key = "temperature";
        foreach (end; key.length .. json.length + 1)
            assert(json[end - key.length .. end] != key, "a zero default leaves the provider default");
    }
}
