/// Bounded provider events and explicit application tool composition.
module flint.engine.ai;

public import flint.engine.ai.client : ChatClient;
public import flint.engine.ai.tools : ToolAuthorization, describeTools, dispatchTool, jsonSchema;
public import flint.engine.ai.types : AiOptions, ChatEvent, ChatMessage, ChatOptions, EventConsumer,
    EventKind, FailureKind, Provider, Role, RouterDialect, Tool, ToolDefinition;

@safe:
