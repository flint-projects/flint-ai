/// Bounded schema-guided mirroring of modern MCP tool parameters.
module flint.engine.mcp.params;

import flint.arena : Error, RequestArena, Status;
import flint.engine.mcp.header_values : encodeHeader;
import flint.engine.mcp.http : equalName;
import flint.engine.mcp.jsonrpc : inspect, isString, malformed, member, readString;
import flint.serde : decodeInto;
import flint.serde.json_visit : JsonMemberName, visitJsonArray;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.engine.mcp):

enum maximumHeaders = 16;
private enum maximumPath = 8;
private enum stringLimit = 1024;

private enum FieldType : ubyte
{
    text,
    integer,
    boolean
}

private struct Name
{
    char[128] bytes;
    size_t length;

    const(char)[] value() const return pure nothrow @nogc
    {
        return bytes[0 .. length];
    }
}

private struct Rule
{
    Name[maximumPath] path;
    size_t depth;
    char[96] name;
    size_t nameLength;
    FieldType kind;

    const(char)[] header() const return pure nothrow @nogc
    {
        return name[0 .. nameLength];
    }
}

struct EncodedField
{
    char[96] name;
    char[1536] value;
    size_t nameLength;
    size_t valueLength;
}

struct ParamRules
{
    private Rule[maximumHeaders] rules;
    private size_t count;
    private Name[maximumPath] path;

    Error readSchema(scope const(ubyte)[] schema) scope nothrow @nogc
    {
        count = 0;
        return collect(schema, 0);
    }

    private Error collect(scope const(ubyte)[] schema, size_t depth) scope nothrow @nogc
    {
        if (schema == cast(const(ubyte)[]) "true" || schema == cast(const(ubyte)[]) "false")
            return Error.init;
        const header = member(schema, "x-mcp-header");
        if (!header.ok())
            return header.error;
        if (header.value.present())
        {
            const added = add(schema, header.value.get(schema), depth);
            if (added.code != Status.ok)
                return added;
        }
        return inspect(schema, (scope JsonMemberName key, size_t offset, size_t length) @safe nothrow @nogc {
            const value = schema[offset .. offset + length];
            if (key.isName("properties"))
                return properties(value, depth);
            if (schemaKeyword(key))
                return forbidden(value);
            return Error.init;
        });
    }

    private Error properties(scope const(ubyte)[] schema, size_t depth) scope nothrow @nogc
    {
        if (depth == path.length)
            return forbidden(schema);
        return inspect(schema, (scope JsonMemberName name, size_t offset, size_t length) @safe nothrow @nogc {
            const child = schema[offset .. offset + length];
            if (name.length() > path[depth].bytes.length)
                return forbidden(child);
            path[depth].length = name.length();
            if (!name.copyName(cast(ubyte[]) path[depth].bytes[]))
                return malformed("invalid MCP schema property name");
            return collect(child, depth + 1);
        });
    }

    private Error add(scope const(ubyte)[] schema, scope const(ubyte)[] annotation, size_t depth) scope nothrow @nogc
    {
        if (depth == 0 || count == rules.length || member(schema, "$ref").value.present())
            return malformed("MCP header annotation has no supported property path");
        enum prefix = "Mcp-Param-";
        scope rule = &rules[count];
        rule.name[0 .. prefix.length] = prefix;
        size_t length;
        if (!readString(annotation, rule.name[prefix.length .. $], length) || !length)
            return malformed("invalid x-mcp-header name");
        rule.nameLength = prefix.length + length;
        foreach (character; rule.name[prefix.length .. rule.nameLength])
        {
            if (!tokenCharacter(character))
                return malformed("invalid x-mcp-header name");
        }
        foreach (ref earlier; rules[0 .. count])
        {
            if (equalName(earlier.header(), rule.header()))
                return malformed("duplicate x-mcp-header name");
        }

        const type = member(schema, "type").value.get(schema);
        if (isString(type, "string"))
            rule.kind = FieldType.text;
        else if (isString(type, "integer"))
            rule.kind = FieldType.integer;
        else if (isString(type, "boolean"))
            rule.kind = FieldType.boolean;
        else
            return malformed("x-mcp-header requires a primitive schema type");
        rule.path[0 .. depth] = path[0 .. depth];
        rule.depth = depth;
        ++count;
        return Error.init;
    }

    Error apply(scope const(ubyte)[] args, scope EncodedField[] output, out size_t used) const scope nothrow @nogc
    {
        foreach (ref rule; rules[0 .. count])
        {
            const value = resolve(args, rule.path[0 .. rule.depth]);
            if (value.length == 0 || value == cast(const(ubyte)[]) "null")
                continue;
            if (used == output.length)
                return Error(Status.resourceExhausted, "MCP header output limit reached");
            output[used].name = rule.name;
            output[used].nameLength = rule.nameLength;
            const checked = format(value, rule.kind, output[used]);
            if (checked.code != Status.ok)
                return checked;
            ++used;
        }
        return Error.init;
    }
}

private const(ubyte)[] resolve(return scope const(ubyte)[] content, scope const(Name)[] path) nothrow @nogc
{
    size_t offset;
    size_t length = content.length;
    foreach (ref segment; path)
    {
        const found = member(content[offset .. offset + length], segment.value());
        if (!found.ok() || !found.value.present())
            return null;
        offset += found.value.offset;
        length = found.value.length;
    }
    return content[offset .. offset + length];
}

private Error format(scope const(ubyte)[] raw, FieldType kind, ref scope EncodedField header) nothrow @nogc
{
    switch (kind)
    {
    case FieldType.text:
        char[stringLimit] text;
        size_t length;
        if (readString(raw, text[], length) && encodeHeader(text[0 .. length], header.value[], header.valueLength))
            return Error.init;
        break;
    case FieldType.integer:
        long[1] number;
        RequestArena noAllocations;
        const parsed = decodeInto(raw, number[0], noAllocations);
        enum bound = 9_007_199_254_740_991L;
        if (parsed.code != Status.ok || number[0] < -bound || number[0] > bound)
            break;
        auto output = JsonWriter(cast(ubyte[]) header.value[]);
        output.signedNumber(number[0]);
        header.valueLength = output.length;
        return Error.init;
    case FieldType.boolean:
        const yes = raw == cast(const(ubyte)[]) "true";
        if (!yes && raw != cast(const(ubyte)[]) "false")
            break;
        header.valueLength = raw.length;
        header.value[0 .. raw.length] = cast(const(char)[]) raw;
        return Error.init;
    default:
        break;
    }
    return malformed("MCP tool argument cannot be represented in its declared header");
}

private bool schemaKeyword(scope JsonMemberName key) nothrow @nogc
{
    static immutable string[] keywords = [
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "items", "prefixItems",
        "additionalItems", "additionalProperties", "patternProperties", "unevaluatedItems",
        "unevaluatedProperties", "contains", "propertyNames", "definitions", "$defs",
        "dependentSchemas", "contentSchema",
    ];
    foreach (name; keywords)
    {
        if (key.isName(name))
            return true;
    }
    return false;
}

private Error forbidden(scope const(ubyte)[] fragment) nothrow @nogc
{
    if (fragment.length == 0)
        return Error.init;
    if (fragment[0] == '[')
        return visitJsonArray(fragment, (scope const(ubyte)[] part) @safe nothrow @nogc => forbidden(part));
    if (fragment[0] != '{')
        return Error.init;
    return inspect(fragment, (scope JsonMemberName key, size_t offset, size_t length) @safe nothrow @nogc {
        if (key.isName("x-mcp-header"))
            return malformed("x-mcp-header must be on a named property path");
        return forbidden(fragment[offset .. offset + length]);
    });
}

private bool tokenCharacter(char value) pure nothrow @nogc
{
    if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9'))
        return true;
    foreach (other; "!#$%&'*+-.^_`|~")
    {
        if (value == other)
            return true;
    }
    return false;
}
