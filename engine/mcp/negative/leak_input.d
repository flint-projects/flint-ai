module leak_input;

import flint.arena : Buffer, RequestArena, Result;
import flint.conc : Context;
import flint.mcp : McpElicitation;

@safe:

private const(ubyte)[] leaked;

/// A response callback must not persist its borrowed request.
McpElicitation unsafeHandler()
{
    return (scope const(ubyte)[] query, ref scope RequestArena output, ref Context context) @safe nothrow @nogc {
        leaked = query;
        return Result!Buffer(Buffer.init);
    };
}
