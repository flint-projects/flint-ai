/// Typed MCP registration and explicit transport options.
module flint.mcp.types;

import flint.arena : Buffer, RequestArena, Result;
import flint.conc : Context;
import flint.web : Request, RequestContext;

@safe:

/// Publish an explicitly registered tool.
struct McpTool
{
    /// Wire name.
    string name;
    /// Application-supplied tool description.
    string description;
    /// Descriptive hint for clients.
    bool readOnly = false;
}

/// Publish an explicitly registered resource.
struct McpResource
{
    /// Stable URI.
    string uri;
    /// MIME type returned with the resource contents.
    string mimeType = "text/plain";
}

/// Select one pinned wire revision.
enum ProtocolRevision : ubyte
{
    modern20260728,
    legacy20251125
}

/// Select one transport binding.
enum Transport : ubyte
{
    stdio,
    streamableHttp
}

/// Decide whether the authenticated HTTP request may enter the MCP endpoint.
alias McpAuthorize = bool delegate(ref scope Request, ref scope RequestContext) @safe nothrow @nogc;

/// Answer an explicit MRTR elicitation request using application policy.
alias McpElicitation = Result!Buffer delegate(scope const(ubyte)[] parameters,
        ref scope RequestArena arena, ref Context context) @safe nothrow @nogc;

/// Configure a bounded MCP listener or stdio service.
struct McpOptions
{
    /// Server implementation name.
    string name;
    /// Server implementation version string.
    string versionString;
    /// Preferred enabled revision.
    ProtocolRevision revision = ProtocolRevision.modern20260728;
    /// Also admit 2025-11-25 handshakes in modern mode.
    bool acceptLegacy = true;
    /// Chosen transport binding.
    Transport transport = Transport.stdio;
    /// HTTP bind address. The default binds local loopback.
    string address = "127.0.0.1";
    /// HTTP listener port.
    ushort port = 3000;
    /// Absolute MCP endpoint path.
    string path = "/mcp";
    /// Maximum envelope bytes.
    size_t maxMessageBytes = 4 * 1024 * 1024;
    /// Maximum admitted owner operations.
    uint maxInFlight = 64;
    /// Exact Origin values admitted when the supplied header is present.
    string[] allowedOrigins;
    /// Required authentication policy for an external listener.
    McpAuthorize authorization;
    /// Optional TLS certificate chain path.
    string tlsCertificateFile;
    /// Optional TLS private key path.
    string tlsPrivateKeyFile;
}

/// Result of a registered action or client call.
struct ToolResult
{
    /// JSON content block array in the active caller arena.
    Buffer content;
    /// Optional JSON object with structured content.
    Buffer structuredContent;
    /// Whether the application reported a tool error.
    bool isError = false;
}

/// Explicit client negotiation, transport and optional elicitation policy.
struct McpClientOptions
{
    /// Requested initial wire revision.
    ProtocolRevision revision = ProtocolRevision.modern20260728;
    /// Permit the 2025-11-25 transport-specific fallback.
    bool acceptLegacy = true;
    /// Maximum input and output envelope bytes.
    size_t maxMessageBytes = 4 * 1024 * 1024;
    /// Optional HTTP Authorization value supplied by the caller.
    string authorization;
    /// Optional PEM trust roots for the HTTP client.
    string caBundle;
    /// Application-controlled handler for in-band elicitation.
    McpElicitation elicitation;
    /// Maximum number of additional rounds in one call.
    uint maxInputRounds = 4;
}

/// An explicit subprocess executable and allowlisted environment.
struct McpProcessOptions
{
    /// Absolute executable path.
    string executable;
    /// Arguments passed after argv[0], with no shell interpretation.
    const(string)[] arguments;
    /// Explicit NAME=VALUE entries passed to the child.
    const(string)[] environment;
}
