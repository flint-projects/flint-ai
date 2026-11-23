/// Startup-generated MCP tables and typed provider adapters.
module flint.engine.mcp.internal.registry;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.mcp.jsonrpc : append, isObject, malformed, maxMethod, maxResource, quote;
import flint.engine.mcp.legacy : SessionKey;
import flint.engine.mcp.internal.blocking : BlockingAction, BlockingInvocation;
import flint.engine.mcp.types : BlockingToolResult, McpResource, McpTool, ToolResult;
import flint.serde : decodeInto, jsonSchema;
import flint.serde.json_write : JsonWriter;
import flint.validate : Violation, validate, validateIn;
import std.traits : Parameters, Unqual;

@safe:
package(flint.engine.mcp):

enum registryCapacity = 128;
enum pageCapacity = 16;

struct Invocation
{
    Result!ToolResult result;
    bool badArguments;
}

alias BeginTool = void delegate() @safe nothrow @nogc;

// dfmt off
alias ToolAction = Invocation delegate(scope const(ubyte)[], ref scope RequestArena,
        ref Context, scope BeginTool) @safe nothrow @nogc;
// dfmt on
alias ResourceAction = Result!Buffer delegate(ref scope RequestArena, ref Context) @safe nothrow @nogc;

struct Tool
{
    McpTool info;
    string schema;
    ToolAction action;
    BlockingAction blocking;
}

struct Resource
{
    McpResource info;
    ResourceAction action;
}

struct Registry
{
    private Tool[registryCapacity] tools;
    private Resource[registryCapacity] resources;
    private size_t toolCount;
    private size_t blockingCount;
    private size_t resourceCount;
    private SessionKey generation;

    Error initialize() nothrow @nogc
    {
        return generation.generate();
    }

    Error add(T)(ref T provider)
    {
        static assert(is(T == class), "MCP provider must be an owned class instance");
        if (provider is null)
            return malformed("MCP provider is null");
        const firstTool = toolCount;
        const firstResource = resourceCount;
        const firstBlocking = blockingCount;
        const result = scan(provider);
        if (result.code == Status.ok && firstTool == toolCount && firstResource == resourceCount)
            return malformed("MCP provider has no registered methods");
        if (result.code != Status.ok)
        {
            tools[firstTool .. toolCount] = Tool.init;
            resources[firstResource .. resourceCount] = Resource.init;
            toolCount = firstTool;
            resourceCount = firstResource;
            blockingCount = firstBlocking;
        }
        return result;
    }

    private Error scan(T)(T provider)
    {
        static foreach (name; __traits(allMembers, T))
        {
            static if (__traits(compiles, __traits(getOverloads, T, name, true)))
            {
                static foreach (index, Member; __traits(getOverloads, T, name, true))
                {
                    static foreach (annotation; __traits(getAttributes, Member))
                    {
                        static if (is(typeof(annotation) == McpTool))
                        {
                            {
                                auto outcome = addTool!(T, name, index, annotation)(provider);
                                if (outcome.code != Status.ok)
                                    return outcome;
                            }
                        }
                        else static if (is(typeof(annotation) == McpResource))
                        {
                            {
                                auto outcome = addResource!(T, name, index, annotation)(provider);
                                if (outcome.code != Status.ok)
                                    return outcome;
                            }
                        }
                    }
                }
            }
        }
        return Error.init;
    }

    private Error addTool(T, string name, size_t index, McpTool marker)(T provider)
    {
        static if (marker.blocking)
            return addBlockingTool!(T, name, index, marker)(provider);
        else
            return addNonblockingTool!(T, name, index, marker)(provider);
    }

    /// A blocking tool: `BlockingToolResult name(Dto input) @safe`, run on the managed worker.
    private Error addBlockingTool(T, string name, size_t index, McpTool marker)(T provider)
    {
        alias Member = __traits(getOverloads, T, name, true)[index];
        alias Args = Parameters!Member;
        static assert(Args.length == 1, "a blocking MCP tool takes its DTO only");
        alias Dto = Unqual!(Args[0]);
        static assert(is(Dto == struct), "MCP tool input must be a struct DTO");
        static assert(__traits(compiles, (T instance, Dto dto) @safe {
                BlockingToolResult output = __traits(getOverloads, instance, name, true)[index](dto);
            }), "a blocking MCP tool must be @safe and return BlockingToolResult");
        const checked = admissible(marker);
        if (checked.code != Status.ok)
            return checked;
        const stored = schemaString!Dto();
        if (!stored.ok())
            return stored.error;
        tools[toolCount++] = Tool(marker, stored.value, null, (scope const(char)[] wire) @safe nothrow{
            import flint.serde.owned : deserialize;

            try
            {
                const parsed = deserialize!Dto(wire.length ? wire : "{}");
                Violation[1] errors;
                if (!parsed.ok || !validate(parsed.value, errors[]).valid)
                    return BlockingInvocation(BlockingToolResult.init, true);
                return BlockingInvocation(__traits(getOverloads, provider, name, true)[index](parsed.value));
            }
            catch (Exception failure)
                return BlockingInvocation(BlockingToolResult(failure.msg.length ? failure.msg
                    : "the MCP tool failed", null, true));
        });
        blockingCount++;
        return Error.init;
    }

    private Error admissible(McpTool marker)
    {
        if (!validText(marker.name, maxMethod) || !validText(marker.description, 4096, true))
            return malformed("invalid MCP tool registration");
        if (findTool(marker.name).action !is null || findTool(marker.name).blocking !is null)
            return Error(Status.conflict, "duplicate MCP tool name");
        if (toolCount == tools.length)
            return Error(Status.resourceExhausted, "MCP tool registry is full");
        return Error.init;
    }

    /// The position of tool `name`, or size_t.max.
    size_t toolPosition(scope const(char)[] name) scope pure nothrow @nogc
    {
        foreach (i, ref entry; tools[0 .. toolCount])
        {
            if (entry.info.name == name)
                return i;
        }
        return size_t.max;
    }

    /// The blocking action at `position`, or null.
    BlockingAction blockingAt(size_t position) nothrow
    {
        return position < toolCount ? tools[position].blocking : null;
    }

    /// Whether any registered tool runs on the managed worker.
    bool hasBlocking() const scope pure nothrow @nogc
    {
        return blockingCount != 0;
    }

    private Error addNonblockingTool(T, string name, size_t index, McpTool marker)(T provider)
    {
        alias Member = __traits(getOverloads, T, name, true)[index];
        alias Args = Parameters!Member;
        static assert(Args.length == 3, "MCP tool requires DTO, arena and context parameters");
        alias Dto = Unqual!(Args[0]);
        static assert(is(Dto == struct), "MCP tool input must be a struct DTO");
        static assert(__traits(compiles, (T instance, ref Dto dto, ref scope RequestArena arena,
                ref Context context) @safe nothrow @nogc {
                Result!ToolResult output = __traits(getOverloads, instance, name, true)[index](dto, arena, context);
            }), "MCP tool must be @safe nothrow @nogc and return Result!ToolResult");
        const checked = admissible(marker);
        if (checked.code != Status.ok)
            return checked;
        const stored = schemaString!Dto();
        if (!stored.ok())
            return stored.error;
        tools[toolCount++] = Tool(marker, stored.value, (scope const(ubyte)[] wire,
                ref scope RequestArena work, ref Context context, scope BeginTool admitted) @safe nothrow @nogc {
            Dto args;
            const parsed = decodeInto(wire, args, work);
            Violation[1] errors;
            if (parsed.code != Status.ok || !validateIn(args, work, errors[]).valid)
                return Invocation(Result!ToolResult(ToolResult.init, malformed("invalid MCP tool arguments")), true);
            const checked = context.check();
            if (checked.code != Status.ok)
                return Invocation(Result!ToolResult(ToolResult.init, checked));
            if (admitted !is null)
                admitted();
            return Invocation(__traits(getOverloads, provider, name, true)[index](args, work, context));
        });
        return Error.init;
    }

    private Error addResource(T, string name, size_t index, McpResource marker)(T provider)
    {
        static assert(__traits(compiles, (T self, ref scope RequestArena work, ref Context ctx) @safe nothrow @nogc {
                Result!Buffer output = __traits(getOverloads, self, name, true)[index](work, ctx);
            }), "MCP resource must be @safe nothrow @nogc and return Result!Buffer");
        if (!validText(marker.uri, maxResource) || !validText(marker.mimeType, 256))
            return malformed("invalid MCP resource registration");
        if (findResource(marker.uri).action !is null)
            return Error(Status.conflict, "duplicate MCP resource URI");
        if (resourceCount == resources.length)
            return Error(Status.resourceExhausted, "MCP resource registry is full");
        resources[resourceCount++] = Resource(marker, &__traits(getOverloads, provider, name, true)[index]);
        return Error.init;
    }

    Tool findTool(scope const(char)[] name) scope pure nothrow @nogc
    {
        foreach (ref entry; tools[0 .. toolCount])
        {
            if (entry.info.name == name)
                return entry;
        }
        return Tool.init;
    }

    Resource findResource(scope const(char)[] uri) scope pure nothrow @nogc
    {
        foreach (ref entry; resources[0 .. resourceCount])
        {
            if (entry.info.uri == uri)
                return entry;
        }
        return Resource.init;
    }

    size_t count(bool selectTools) const scope pure nothrow @nogc
    {
        return selectTools ? toolCount : resourceCount;
    }

    size_t position(scope const(char)[] cursor, bool selectTools) const scope pure nothrow @nogc
    {
        enum prefix = 33;
        if (cursor.length <= prefix || cursor.length > prefix + 3
                || cursor[0] != cursorType(selectTools) || cursor[1 .. prefix] != generation.text[])
            return size_t.max;
        size_t offset;
        foreach (digit; cursor[prefix .. $])
        {
            if (digit < '0' || digit > '9')
                return size_t.max;
            offset = offset * 10 + digit - '0';
        }
        return offset > 0 && offset < count(selectTools) && offset % pageCapacity == 0 ? offset : size_t.max;
    }

    void emitPage(ref scope JsonWriter output, bool selectTools, size_t start) const scope nothrow @nogc
    {
        append(output, selectTools ? `"tools":[` : `"resources":[`);
        const total = count(selectTools);
        const end = total - start > pageCapacity ? start + pageCapacity : total;
        foreach (index; start .. end)
        {
            if (index != start)
                append(output, ",");
            if (selectTools)
                writeTool(output, tools[index]);
            else
                writeResource(output, resources[index]);
        }
        append(output, "]");
        if (end < total)
        {
            append(output, `,"nextCursor":"`);
            output.put(cursorType(selectTools));
            append(output, generation.text[]);
            output.unsignedNumber(end);
            output.put('"');
        }
    }
}

private ubyte cursorType(bool selectTools) pure nothrow @nogc
{
    return selectTools ? 't' : 'r';
}

private void writeTool(ref scope JsonWriter output, scope const ref Tool entry) nothrow @nogc
{
    append(output, `{"name":`);
    quote(output, entry.info.name);
    append(output, `,"description":`);
    quote(output, entry.info.description);
    append(output, `,"inputSchema":`);
    append(output, entry.schema);
    append(output, `,"annotations":{"readOnlyHint":`);
    append(output, entry.info.readOnly ? "true}}" : "false}}");
}

private void writeResource(ref scope JsonWriter output, scope const ref Resource entry) nothrow @nogc
{
    append(output, `{"uri":`);
    quote(output, entry.info.uri);
    append(output, `,"name":`);
    quote(output, entry.info.uri);
    append(output, `,"mimeType":`);
    quote(output, entry.info.mimeType);
    append(output, "}");
}

bool validText(scope const(char)[] value, size_t maximum, bool empty = false) nothrow @nogc
{
    if ((!empty && value.length == 0) || value.length > maximum)
        return false;
    JsonWriter check;
    quote(check, value);
    return check.error.code == Status.ok;
}

private Result!string schemaString(T)()
{
    scope memory = new ubyte[32 * 1024];
    auto arena = RequestArena(memory);
    const schema = jsonSchema!T(arena);
    return schema.ok() ? duplicate(arena, schema.value) : Result!string(null, schema.error);
}

private Result!string duplicate(ref scope RequestArena arena, Buffer handle)
{
    auto bytes = new char[handle.length()];
    const code = arena.read(handle, (scope const(ubyte)[] value) @safe nothrow @nogc {
        bytes[] = cast(const(char)[]) value;
    });
    return code == Status.ok ? Result!string(bytes.idup) : Result!string(null, Error(code, "MCP schema was lost"));
}
