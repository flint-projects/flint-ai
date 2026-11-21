module unsafe_provider;

import flint.arena : RequestArena, Result;
import flint.conc : Context;
import flint.mcp : McpServer, McpTool, ToolResult, registerMcp;

@safe:

struct Arguments
{
    long value;
}

final class UnsafeTool
{
    @McpTool("unsafe", "Cannot register unsafe work")
    Result!ToolResult execute(ref Arguments input, ref scope RequestArena arena, ref Context context) @system nothrow @nogc
    {
        return Result!ToolResult(ToolResult.init);
    }
}

void register(ref McpServer server, ref UnsafeTool provider)
{
    registerMcp(server, provider);
}
