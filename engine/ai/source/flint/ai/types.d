module flint.ai.types;

import flint.arena : Buffer, Error, RequestArena;

@safe:

/// Name and description of an explicitly registered application tool.
struct Tool
{
    /// Provider-visible name.
    string name;
    /// Description sent with an application-owned tool definition.
    string description;
}

/// The selected provider request and event dialect.
enum Provider : ubyte
{
    openAI,
    anthropic,
    gemini,
    openRouter
}

/// Role of one conversation message.
enum Role : ubyte
{
    system,
    user,
    assistant,
    tool
}

/// Observations emitted while a provider request is active.
enum EventKind : ubyte
{
    textDelta,
    toolDelta,
    usage,
    completed,
    failed
}

/// Explicit selection of the OpenRouter request dialect.
enum RouterDialect : ubyte
{
    responses,
    chatCompletions
}

/// Reason for a failed or interrupted request.
enum FailureKind : ubyte
{
    none,
    provider,
    refused,
    incomplete,
    cancelled
}

/// Content owned by the request arena.
struct ChatMessage
{
    /// Conversation role.
    Role role;
    /// UTF-8 text in the supplied request arena.
    Buffer content;
    /// Provider call ID for an application-supplied tool response.
    string toolCallId;
    /// Name for a tool result or an assistant call. An assistant call's content holds JSON arguments.
    string toolName;
    /// Optional provider-issued state for a Gemini function part.
    string providerState;
}

/// One tool definition and an encoded JSON object schema in the request arena.
struct ToolDefinition
{
    /// Public declaration.
    Tool tool;
    /// Input schema produced by the typed registry.
    Buffer parameters;
}

/// Bounded context for one request.
struct ChatOptions
{
    /// Model chosen by the application.
    string model;
    /// Provider output token limit.
    uint maxOutputTokens = 1024;
    /// Sampling temperature.
    double temperature;
    /// Application-controlled continuation limit.
    uint maxToolRounds = 8;
    /// Maximum decoded bytes in one event.
    size_t maxEventBytes = 1024 * 1024;
    /// Number of tool rounds already completed in this conversation.
    uint toolRounds;
    /// Advertised tools. The transport does not execute them.
    const(ToolDefinition)[] tools;
    /// Send an explicit zero rather than using the provider's default temperature.
    bool sendTemperature;
    /// Number of retries after an explicit prestream transient HTTP response.
    uint maxPrestreamRetries = 1;
}

/// One typed observation delivered synchronously to the application.
struct ChatEvent
{
    /// Provider-neutral event category.
    EventKind kind;
    /// Text or complete tool arguments in the event arena.
    Buffer text;
    /// Stable bounded routing name within a single request.
    string toolCallId;
    /// Normalized provider input use.
    uint inputTokens;
    /// Normalized provider output use.
    uint outputTokens;
    /// Provider call ID bytes. Copy them before retaining them outside the callback.
    Buffer providerCallId;
    /// Tool name bytes from the provider.
    Buffer toolName;
    /// Additional detail for a failed event.
    FailureKind failure;
    /// Opaque continuation state. Copy it as bytes without parsing or logging it.
    Buffer providerState;
    /// Whether the provider requires the supplied ID to appear in the continuation.
    bool providerAssignedId;
}

/// Receive a complete event using its short-lived arena.
alias EventConsumer = Error delegate(ref ChatEvent event, ref scope RequestArena arena) @safe nothrow @nogc;

/// Explicit provider configuration and connection bounds.
struct AiOptions
{
    /// Provider request dialect.
    Provider provider;
    /// Operator-configured base URL.
    string baseUrl;
    /// Credential supplied by the caller.
    string apiKey;
    /// API version when required by this provider.
    string apiVersion;
    /// Maximum simultaneous requests on this client.
    uint maxConcurrentRequests = 32;
    /// Trust bundle for an explicitly configured private endpoint.
    string caBundle;
    /// Allow numeric loopback cleartext for local transport verification.
    bool allowLoopbackCleartext;
    /// OpenRouter compatibility requires explicit selection.
    RouterDialect routerDialect;
    /// Largest event workspace reserved per concurrent request.
    size_t maxBufferedEventBytes = 1024 * 1024;
    /// Largest encoded provider request reserved per concurrent request.
    size_t maxRequestBytes = 1024 * 1024;
}
