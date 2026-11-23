module flint_ai_negative.duplicate_tools;

import flint.engine.ai : Tool, dispatchTool;
import flint.arena : Error, RequestArena;
import flint.conc : Context;
import std.meta : AliasSeq;

@safe:

private struct Arguments
{
    int value;
}

private struct Registry
{
    @Tool("same", "first")
    Error first(scope const ref Arguments, ref Arguments, ref scope RequestArena, ref Context) nothrow @nogc
    {
        return Error.init;
    }

    @Tool("same", "second")
    Error second(scope const ref Arguments, ref Arguments, ref scope RequestArena, ref Context) nothrow @nogc
    {
        return Error.init;
    }

    alias ToolMethods = AliasSeq!(first, second);
}

private void ambiguous(ref Registry tools, ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    dispatchTool(tools, "same", null, arena, context);
}
