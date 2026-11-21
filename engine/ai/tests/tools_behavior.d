module flint.ai.tools_behavior;

import flint.ai : Tool, ToolDefinition, describeTools, dispatchTool;
import flint.arena : Error, RequestArena, Status;
import flint.conc : Context;
import flint.validate : Min;
import std.meta : AliasSeq;

@safe:

private struct Arguments
{
    @Min(1) int quantity;
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
