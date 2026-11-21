module flint_ai_negative.pointer_schema;

import flint.ai : jsonSchema;
import flint.arena : RequestArena;

@safe:

private struct PointerArgument
{
    int* cursor;
}

private void unsupported(ref scope RequestArena arena) nothrow @nogc
{
    jsonSchema!PointerArgument(arena);
}
