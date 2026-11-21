module flint.ai.client_behavior;

import flint.ai : AiOptions, ChatClient, ChatEvent, ChatMessage, ChatOptions, EventKind,
    FailureKind, Provider, Role, RouterDialect;
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

    chat.toolRounds = 9;
    assert(client.stream(messages, chat, arena, context, &rejected.receive).code == Status.resourceExhausted);
}
