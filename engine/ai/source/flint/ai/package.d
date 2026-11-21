/// Bounded provider events and explicit application tool composition.
module flint.ai;

public import flint.ai.client : ChatClient;
public import flint.ai.tools : ToolAuthorization, describeTools, dispatchTool, jsonSchema;
public import flint.ai.types : AiOptions, ChatEvent, ChatMessage, ChatOptions, EventConsumer,
    EventKind, FailureKind, Provider, Role, RouterDialect, Tool, ToolDefinition;

@safe:
