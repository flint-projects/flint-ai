module flint_ai_negative.cyclic_schema;

import flint.ai : jsonSchema;
import flint.arena : RequestArena;

@safe:

private struct NodeArgument
{
    NodeArgument* next;
}

private void unsupported(ref scope RequestArena arena) nothrow @nogc
{
    jsonSchema!NodeArgument(arena);
}
