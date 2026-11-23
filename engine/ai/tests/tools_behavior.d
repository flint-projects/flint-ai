module flint.engine.ai.tools_behavior;

import flint.engine.ai : Tool, ToolDefinition, describeTools, dispatchTool;
import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.validate : Min;
import std.meta : AliasSeq;

@safe:

private struct Arguments
{
    @Min(1)
    int quantity;
}

private struct Answer
{
    int quantity;
}

private struct Registry
{
    uint invoked;

    @Tool("inventory", "Read an inventory observation.")
    Error handle(scope const ref Arguments args, ref Answer output, ref scope RequestArena, ref Context) nothrow @nogc
    {
        ++invoked;
        output.quantity = args.quantity * 2;
        return Error.init;
    }

    alias ToolMethods = AliasSeq!handle;
}

@("only explicit dispatch of valid authorized arguments invokes the registered tool")
unittest
{
    ubyte[8192] bytes;
    scope RequestArena arena = RequestArena(bytes[]);
    ToolDefinition[1] definitions;
    assert(describeTools!Registry(arena, definitions[]).code == Status.ok);
    assert(definitions[0].tool.name == "inventory" && definitions[0].parameters.length > 0);
    Registry tools;
    Context context;
    const valid = cast(const(ubyte)[]) `{"quantity":5}`;
    const invalid = cast(const(ubyte)[]) `{"quantity":0}`;
    const partial = cast(const(ubyte)[]) `{"quantity":`;
    assert(dispatchTool(tools, "unregistered", valid, arena, context).error.code == Status.notFound);
    assert(dispatchTool(tools, "inventory", invalid, arena, context).error.code == Status.invalidArgument);
    assert(dispatchTool(tools, "inventory", partial, arena, context).error.code == Status.invalidArgument);
    const denied = dispatchTool(tools, "inventory", valid, arena, context, (scope const(char)[],
            ref Context) @safe nothrow @nogc => Error(Status.permissionDenied));
    assert(denied.error.code == Status.permissionDenied && tools.invoked == 0);
    const called = dispatchTool(tools, "inventory", valid, arena, context);
    assert(called.ok && tools.invoked == 1);
    assert(arena.read(called.value, (scope const(ubyte)[] encoded) @safe nothrow @nogc {
            assert(encoded == cast(const(ubyte)[]) `{"quantity":10}`);
        }) == Status.ok);
}

private struct Destructive
{
    uint invoked;

    @Tool("delete_everything", "Irreversibly remove all records.")
    Error handle(scope const ref Arguments args, ref Answer output, ref scope RequestArena, ref Context) nothrow @nogc
    {
        ++invoked;
        output.quantity = args.quantity;
        return Error.init;
    }

    alias ToolMethods = AliasSeq!handle;
}

@("tool_authorization: a model-emitted destructive call is only an event until the app dispatches it")
unittest
{
    import flint.engine.ai.events : EventRun;
    import flint.engine.ai.providers.openai : responsesEvent;
    import flint.engine.ai.tool_calls : ArgumentBlock;
    import flint.engine.ai.types : ChatEvent, EventKind;

    Destructive tools;
    auto run = EventRun(new ArgumentBlock[8]);
    ubyte[8192] scratch;
    scope RequestArena arena = RequestArena(scratch[]);
    immutable string[] trace = [
        `{"type":"response.output_item.added","item":{"type":"function_call","id":"a",`
        ~ `"call_id":"1","name":"delete_everything"}}`,
        q{{"type":"response.function_call_arguments.done","item_id":"a","arguments":"{\"quantity\":3}"}},
        q{{"type":"response.completed","response":{"usage":null}}}
    ];
    uint toolEvents, completions;
    foreach (record; trace)
    {
        assert(arena.reset() == Status.ok);
        const parsed = responsesEvent("message", cast(const(ubyte)[]) record, run, arena,
                (ref ChatEvent event, ref scope RequestArena) @safe nothrow @nogc {
            toolEvents += event.kind == EventKind.toolDelta;
            completions += event.kind == EventKind.completed;
            return Error.init;
        });
        assert(parsed.code == Status.ok, parsed.message);
    }
    assert(toolEvents == 1 && completions == 1 && tools.invoked == 0);

    Context context;
    const arguments = cast(const(ubyte)[]) `{"quantity":3}`;
    const refused = dispatchTool(tools, "delete_everything", arguments, arena, context,
            (scope const(char)[], ref Context) @safe nothrow @nogc => Error(Status.permissionDenied,
                "destructive tools require operator approval"));
    assert(refused.error.code == Status.permissionDenied && tools.invoked == 0);

    import flint.conc : CancelSource, Deadline;

    auto source = CancelSource.create(Context.init, Deadline.afterMillis(60_000));
    auto expired = source.value.context();
    source.value.cancel();
    assert(dispatchTool(tools, "delete_everything", arguments, arena, expired).error.code == Status.cancelled);
    assert(tools.invoked == 0);
    assert(dispatchTool(tools, "delete_everything", arguments, arena, context).ok && tools.invoked == 1);
}
