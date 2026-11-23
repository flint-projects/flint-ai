module unsafe_provider;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.engine.mcp : McpServer, McpTool, ToolResult, registerMcp;

@safe:

/// Input for the deliberately unsafe provider.
struct Arguments
{
    /// Unused test value.
    long value;
}

/// Provider rejected by compile-time attribute checking.
final class UnsafeTool
{
    /// An unchecked handler cannot enter the typed registry.
    @McpTool("unsafe", "Cannot register unsafe work")
    @system nothrow @nogc Result!ToolResult execute(ref Arguments input, ref scope RequestArena arena,
            ref Context context)
    {
        return Result!ToolResult(ToolResult.init);
    }
}

/// Instantiate the failing registration.
void register(ref McpServer server, ref UnsafeTool provider)
{
    registerMcp(server, provider);
}
