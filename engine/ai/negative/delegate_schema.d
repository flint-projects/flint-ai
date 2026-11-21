module flint_ai_negative.delegate_schema;

import flint.ai : jsonSchema;
import flint.arena : RequestArena;

@safe:

private struct CallableArgument
{
    int delegate() routine;
}

private void unsupported(ref scope RequestArena arena) nothrow @nogc
{
    jsonSchema!CallableArgument(arena);
}
