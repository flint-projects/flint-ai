/// Versioned MCP server and client with explicit tool and resource registration.
module flint.mcp;

import flint.arena : Error, Status;
import flint.conc : Context;
import flint.mcp.http : HttpEndpoint;
import flint.mcp.jsonrpc : maxMessage;
import flint.mcp.protocol : Protocol;
import flint.mcp.internal.registry : validText;
import flint.mcp.stdio : StdioEndpoint;
public import flint.mcp.client : McpClient;
public import flint.mcp.types : McpAuthorize, McpClientOptions, McpElicitation, McpOptions,
    McpProcessOptions, McpResource, McpTool, ProtocolRevision, ToolResult, Transport;

@safe:

/// One owner of a prepared MCP endpoint. Register providers before running it.
struct McpServer
{
    private Protocol protocol;
    private HttpEndpoint http;
    private StdioEndpoint stdio;
    private bool didRun;

    @disable this(this);

    /// Prepare the configured transport and reserve its bounded storage.
    Error open(McpOptions options)
    {
        if (protocol !is null)
            return Error(Status.conflict, "MCP server is already open");
        if (!validOptions(options))
            return Error(Status.invalidArgument, "invalid MCP server options");
        options.allowedOrigins = options.allowedOrigins.dup;
        auto driver = new Protocol(options);
        const initialized = driver.registry.initialize();
        if (initialized.code != Status.ok)
            return initialized;
        if (options.transport == Transport.streamableHttp)
        {
            auto endpoint = new HttpEndpoint(driver, options);
            const opened = endpoint.open();
            if (opened.code != Status.ok)
                return opened;
            http = endpoint;
        }
        else
        {
            auto endpoint = new StdioEndpoint(driver, options);
            const opened = endpoint.open();
            if (opened.code != Status.ok)
                return opened;
            stdio = endpoint;
        }
        protocol = driver;
        return Error.init;
    }

    /// Serve until standard input closes, the context ends, or the transport fails.
    Error run(ref Context context) nothrow @nogc
    {
        if (protocol is null || didRun)
            return Error(Status.conflict, "MCP server is closed or has already served");
        didRun = true;
        return http is null ? stdio.run(context) : http.run(context);
    }

    /// Stop new work and release transport state after in-flight work ends.
    Error close(ref Context context) nothrow @nogc
    {
        if (protocol is null)
            return Error.init;
        const stopped = http is null ? stdio.close(context) : http.close(context);
        if (stopped.code != Status.timedOut && stopped.code != Status.conflict)
        {
            http = null;
            stdio = null;
            protocol = null;
            didRun = false;
        }
        return stopped;
    }
}

/// Register the methods annotated with McpTool or McpResource as one startup transaction.
Error registerMcp(T)(ref McpServer server, ref T provider)
{
    if (server.protocol is null || server.didRun)
        return Error(Status.conflict, "MCP registration requires a prepared server");
    return server.protocol.registry.add(provider);
}

private bool validOptions(scope const ref McpOptions options) nothrow @nogc
{
    if (!validText(options.name, 256) || !validText(options.versionString, 256)
            || options.maxMessageBytes < 1024 || options.maxMessageBytes > maxMessage || options.maxInFlight == 0
            || options.maxInFlight > 64 || options.revision > ProtocolRevision.legacy20251125
            || options.transport > Transport.streamableHttp || options.allowedOrigins.length > 32)
        return false;
    foreach (entry; options.allowedOrigins)
    {
        if (!validText(entry, 4096))
            return false;
    }
    if (options.transport == Transport.streamableHttp)
    {
        if (options.path.length == 0 || options.path.length > 1024 || options.path[0] != '/')
            return false;
        foreach (character; options.path)
        {
            if (character <= ' ' || character == '?' || character == '#' || character == ':' || character == '*')
                return false;
        }
    }
    return true;
}
