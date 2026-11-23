module flint_ai_negative.slice_cycle_schema;

import flint.engine.ai : jsonSchema;
import flint.arena : RequestArena;

@safe:

private struct TreeArgument
{
    int value;
    TreeArgument[] children;
}

private void unsupported(ref scope RequestArena arena) nothrow @nogc
{
    jsonSchema!TreeArgument(arena);
}
