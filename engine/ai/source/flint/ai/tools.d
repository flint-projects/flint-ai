/// Explicit typed application tool dispatch and schema registration.
module flint.ai.tools;

import flint.ai.types : Tool, ToolDefinition;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.serde : decodeInto, encodeJson, serdeSchema = jsonSchema;
import flint.validate : Violation, validateIn;
import std.traits : Parameters, Unqual, getUDAs;

@safe:

/// Check an explicit application dispatch before decoding or invoking a tool.
alias ToolAuthorization = Error delegate(scope const(char)[] name, ref Context) @safe nothrow @nogc;

private bool validToolName(scope const(char)[] name) pure nothrow @nogc
{
    if (name.length == 0 || name.length > 64)
        return false;
    foreach (char character; name)
    {
        const lower = character >= 'a' && character <= 'z';
        const upper = character >= 'A' && character <= 'Z';
        const digit = character >= '0' && character <= '9';
        if (!lower && !upper && !digit && character != '_' && character != '-')
            return false;
    }
    return true;
}

private template ToolRegistration(alias method)
{
    alias tags = getUDAs!(method, Tool);
    static assert(tags.length == 1, "registered tool methods require exactly one Tool annotation");
    enum descriptor = tags[0];
    static assert(validToolName(descriptor.name), "invalid registered tool name");
    static assert(is(typeof(method)), "a registered tool must name a method");
    static assert(Parameters!method.length == 4, "tool methods require arguments, result, arena and context");
    alias Input = Unqual!(Parameters!method[0]);
    alias Output = Unqual!(Parameters!method[1]);
    alias Function = ToolRegistrationFunction!(Input, Output);
}

private bool uniqueTools(T)()
{
    static assert(__traits(hasMember, T, "ToolMethods"), "declare an explicit alias ToolMethods tuple");
    enum count = T.ToolMethods.length;
    static assert(count <= 32, "at most 32 tool methods can be registered");
    string[count] names;
    static foreach (index, method; T.ToolMethods)
        names[index] = ToolRegistration!method.descriptor.name;
    foreach (index, name; names)
        foreach (previous; names[0 .. index])
            if (name == previous)
                return false;
    return true;
}

/// Generate the supported JSON Schema for one declared tool input or model DTO.
Result!Buffer jsonSchema(T)(ref scope RequestArena arena) nothrow @nogc
{
    return serdeSchema!T(arena);
}

/// Populate definitions from an explicit alias ToolMethods tuple.
Error describeTools(T)(ref scope RequestArena arena, scope ToolDefinition[] definitions) nothrow @nogc
{
    static assert(uniqueTools!T(), "duplicate names in the tool registry");
    if (definitions.length != T.ToolMethods.length)
        return Error(Status.invalidArgument, "tool definition capacity differs from registry");
    static foreach (index, method; T.ToolMethods)
    {
        {
            alias registration = ToolRegistration!method;
            const descriptor = jsonSchema!(registration.Input)(arena);
            if (!descriptor.ok)
                return descriptor.error;
            definitions[index] = ToolDefinition(registration.descriptor, descriptor.value);
        }
    }
    return Error.init;
}

private Result!Buffer denied(Error status) pure nothrow @nogc
{
    return Result!Buffer(Buffer.init, status);
}

/// Dispatch only when called explicitly by the application.
Result!Buffer dispatchTool(T)(ref T tools, scope const(char)[] name, scope const(ubyte)[] arguments,
        ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    return dispatchTool(tools, name, arguments, arena, context, null);
}

/// Dispatch after an explicit application authorization callback.
Result!Buffer dispatchTool(T)(ref T tools, scope const(char)[] name, scope const(ubyte)[] arguments,
        ref scope RequestArena arena, ref Context context, scope ToolAuthorization permit) nothrow @nogc
{
    static assert(uniqueTools!T(), "duplicate names in the tool registry");
    const current = context.check();
    if (current.code != Status.ok)
        return denied(current);
    static foreach (method; T.ToolMethods)
    {
        {
            alias registration = ToolRegistration!method;
            if (name == registration.descriptor.name)
            {
                if (permit !is null)
                {
                    const allowed = permit(name, context);
                    if (allowed.code != Status.ok)
                        return denied(allowed);
                }
                enum memberName = __traits(identifier, method);
                static assert(is(typeof(&__traits(getMember, tools,
                        memberName)) : registration.Function), "invalid typed tool method signature");
                scope registration.Function action = &__traits(getMember, tools, memberName);
                return invoke!(registration.Input, registration.Output)(action, arguments, arena, context);
            }
        }
    }
    return denied(Error(Status.notFound, "tool is not registered"));
}

private Result!Buffer invoke(Input, Output)(scope ToolRegistrationFunction!(Input, Output) run,
        scope const(ubyte)[] arguments, ref scope RequestArena arena, ref Context context) nothrow @nogc
{
    Input input;
    const parsed = decodeInto(arguments, input, arena);
    if (parsed.code != Status.ok)
        return denied(parsed);
    Violation[1] violations;
    if (!validateIn(input, arena, violations[]).valid)
        return denied(Error(Status.invalidArgument, "tool arguments did not satisfy their constraints"));
    const pending = context.check();
    if (pending.code != Status.ok)
        return denied(pending);
    Output output;
    const handled = run(input, output, arena, context);
    return handled.code == Status.ok ? encodeJson(output, arena) : denied(handled);
}

private alias ToolRegistrationFunction(Input, Output) = Error delegate(scope const ref Input,
        ref Output, ref scope RequestArena, ref Context) @safe nothrow @nogc;
