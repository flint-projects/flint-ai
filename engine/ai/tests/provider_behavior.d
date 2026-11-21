module flint.ai.provider_behavior;

import flint.ai.events : EventRun;
import flint.ai.providers.anthropic : AnthropicStream;
import flint.ai.providers.gemini : GeminiStream;
import flint.ai.providers.openai : responsesEvent;
import flint.ai.providers.openrouter : RouterChatStream, routerResponsesEvent;
import flint.ai.tool_calls : ArgumentBlock;
import flint.ai.types : ChatEvent, EventConsumer, EventKind, FailureKind;
import flint.arena : Error, RequestArena, Status;

@safe:

private struct Transcript
{
    uint texts, tools, completions, usages, input, output;
    FailureKind failure;
    char[128] bytes;
    size_t size;

    Error event(ref ChatEvent current, ref scope RequestArena arena) scope nothrow @nogc
    {
        final switch (current.kind)
        {
        case EventKind.textDelta:
            ++texts;
            break;
        case EventKind.toolDelta:
            ++tools;
            assert(current.toolCallId && current.providerCallId.length != 0 && current.toolName.length != 0);
            break;
        case EventKind.usage:
            ++usages;
            input = current.inputTokens;
            output = current.outputTokens;
            return Error.init;
        case EventKind.completed:
            ++completions;
            return Error.init;
        case EventKind.failed:
            failure = current.failure;
            break;
        }
        const seen = arena.read(current.text, (scope const(ubyte)[] data) @safe nothrow @nogc {
            assert(data.length <= bytes.length - size);
            bytes[size .. size + data.length] = cast(const(char)[]) data;
            size += data.length;
        });
        return Error(seen);
    }
}

private alias Receiver = Error delegate(scope const(char)[] name, scope const(ubyte)[] json,
        ref scope EventRun run, ref scope RequestArena arena, scope EventConsumer consume) @safe nothrow @nogc;

private void replay(scope Receiver receive, scope const string[] fixtures, ref scope EventRun run,
        ref scope RequestArena arena, ref Transcript observed) nothrow @nogc
{
    foreach (record; fixtures)
    {
        assert(arena.reset() == Status.ok);
        const parsed = receive("message", cast(const(ubyte)[]) record, run, arena, &observed.event);
        assert(parsed.code == Status.ok, parsed.message);
    }
}

@("Responses interleaves tool calls, deduplicates completion, and accepts absent usage")
unittest
{
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    Transcript observed;
    scope Receiver receive = (scope const(char)[] name, scope const(ubyte)[] data,
            ref scope EventRun stream, ref scope RequestArena eventArena, scope EventConsumer consumer) {
        return responsesEvent(name, data, stream, eventArena, consumer);
    };
    immutable string[] trace = [
        q{{"type":"response.output_item.added","item":{"type":"function_call","id":"a","call_id":"1","name":"get"}}},
        q{{"type":"response.output_item.added","item":{"type":"function_call","id":"b","call_id":"2","name":"get"}}},
        q{{"type":"response.function_call_arguments.delta","item_id":"a","delta":"{\"a\":"}},
        q{{"type":"response.function_call_arguments.delta","item_id":"b","delta":"{\"b\":"}},
        q{{"type":"response.function_call_arguments.delta","item_id":"a","delta":"1}"}},
        q{{"type":"response.function_call_arguments.delta","item_id":"b","delta":"2}"}},
        q{{"type":"response.function_call_arguments.done","item_id":"b","arguments":"{\"b\":2}"}},
        q{{"type":"response.function_call_arguments.done","item_id":"a","arguments":"{\"a\":1}"}},
        q{{"type":"response.function_call_arguments.done","item_id":"a","arguments":"{\"a\":1}"}},
        q{{"type":"response.completed","response":{"usage":null}}}
    ];
    replay(receive, trace, run, arena, observed);
    assert(observed.tools == 2 && observed.completions == 1 && observed.usages == 0);
    assert(observed.bytes[0 .. observed.size] == q{{"b":2}{"a":1}});
}

@("Messages retains cumulative usage and completes the tool only at block stop")
unittest
{
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    AnthropicStream adapter;
    Transcript observed;
    immutable string[] trace = [
        q{{"type":"message_start","message":{"usage":{"input_tokens":9,"output_tokens":1}}}},
        `{"type":"content_block_start","index":2,`
        ~ `"content_block":{"type":"tool_use","id":"a","name":"get","input":{}}}`,
        q{{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}},
        q{{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"3}"}}},
        q{{"type":"content_block_stop","index":2}},
        q{{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":3}}},
        q{{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":6}}},
        q{{"type":"message_stop"}}
    ];
    replay(&adapter.event, trace[0 .. 4], run, arena, observed);
    assert(observed.tools == 0);
    replay(&adapter.event, trace[4 .. $], run, arena, observed);
    assert(observed.tools == 1 && observed.completions == 1 && observed.usages == 1);
    assert(observed.input == 9 && observed.output == 6);
}

@("Gemini waits for a finish reason and omits hidden thought parts")
unittest
{
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    GeminiStream adapter;
    Transcript observed;
    immutable string[] trace = [q{{
        "candidates":[{"index":0,"content":{"parts":[{"text":"hidden","thought":true},
        {"text":"é"},{"functionCall":{"name":"get","args":{"a":4}}}]},"finishReason":"STOP"}],
        "usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":2}
    }}];
    replay(&adapter.event, trace, run, arena, observed);
    assert(adapter.finished && observed.texts == 1 && observed.tools == 1 && observed.completions == 0);
    assert(run.success(arena, &observed.event).code == Status.ok);
    assert(observed.bytes[0 .. observed.size] == "é" ~ q{{"a":4}});
    assert(observed.completions == 1 && observed.usages == 1 && observed.input == 7 && observed.output == 2);
}

@("OpenRouter Chat accounts for its repeated terminal usage chunk only once")
unittest
{
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    RouterChatStream adapter;
    Transcript observed;
    immutable string[] trace = [
        q{{"choices":[{"index":0,"delta":{"content":null,"tool_calls":[
            {"index":0,"id":"call_1","function":{"name":"get","arguments":"{\"a\":"}}]},"finish_reason":null}]}},
        `{"choices":[{"index":0,"delta":{"tool_calls":[`
        ~ `{"index":0,"function":{"arguments":"5}"}}]},"finish_reason":null}]}`,
        q{{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls"}]}},
        `{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls"}],`
        ~ `"usage":{"prompt_tokens":8,"completion_tokens":9}}`, "[DONE]", "[DONE]"
    ];
    replay(&adapter.event, trace, run, arena, observed);
    assert(observed.tools == 1 && observed.usages == 1 && observed.completions == 1);
    assert(observed.input == 8 && observed.output == 9);
}

@("OpenRouter Responses handles its provider envelope before semantic events")
unittest
{
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    auto arena = RequestArena(scratch[]);
    Transcript observed;
    const parsed = routerResponsesEvent("message",
            cast(const(ubyte)[]) q{{"error":{"message":"private"}}}, run, arena, &observed.event);
    assert(parsed.code == Status.unavailable);
    assert(observed.failure == FailureKind.provider && observed.completions == 0);
    assert(observed.bytes[0 .. observed.size] == "OpenRouter reported a provider error");
}

@("Responses refusal never produces a completed event")
unittest
{
    auto run = EventRun(new ArgumentBlock[1]);
    ubyte[512] scratch;
    auto arena = RequestArena(scratch[]);
    Transcript observed;
    enum refused = q{{"type":"response.refusal.delta","delta":"raw provider detail"}};
    const parsed = responsesEvent("response.refusal.delta", cast(const(ubyte)[]) refused, run,
            arena, &observed.event);
    assert(parsed.code == Status.permissionDenied && observed.failure == FailureKind.refused);
    assert(observed.completions == 0 && observed.bytes[0 .. observed.size] == "provider refused the request");
}
