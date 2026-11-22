/// flint-mcp: serves the Flint knowledge and build loop over MCP stdio. `flint mcp` builds and starts it.
module flint_mcp.app;

import flint_mcp.tools : FlintTools;
import flint.arena : Status;
import flint.conc : Context;
import flint.mcp : McpOptions, McpServer, registerMcp;

@safe:

int main()
{
    import std.process : environment;

    McpOptions options;
    options.name = "flint";
    options.versionString = "0.9.0";
    options.maxInFlight = 4;
    McpServer server;
    if (server.open(options).code != Status.ok)
        return 2;
    Context cleanup;
    scope (exit)
        server.close(cleanup);
    auto tools = new FlintTools(environment.get("FLINT_EXECUTABLE", "flint"), environment.get("FLINT_MCP_LOG", ""));
    if (registerMcp(server, tools).code != Status.ok)
        return 3;
    Context serve;
    return server.run(serve).code == Status.ok ? 0 : 4;
}
