/// 2026-07-28 per-request metadata and result fields.
module flint.mcp.modern;

import flint.arena : Error, Result, Status;
import flint.mcp.jsonrpc : Range, append, inspect, isObject, member, quote, readString;
import flint.serde.json_visit : JsonMemberName;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.mcp):

enum modernRevision = "2026-07-28";
enum versionField = "io.modelcontextprotocol/protocolVersion";
enum capabilitiesField = "io.modelcontextprotocol/clientCapabilities";
enum clientInfoField = "io.modelcontextprotocol/clientInfo";
enum serverInfoField = "io.modelcontextprotocol/serverInfo";

struct Metadata
{
    char[64] revisionStorage;
    size_t length;
    bool declared;
    bool valid;

    const(char)[] revision() const return pure nothrow @nogc
    {
        return revisionStorage[0 .. length];
    }
}

private struct Entries
{
    Range release, capabilities, info;

    Error read(scope JsonMemberName key, size_t offset, size_t length) nothrow @nogc
    {
        const location = Range(offset, length);
        if (key.isName(versionField))
            release = location;
        else if (key.isName(capabilitiesField))
            capabilities = location;
        else if (key.isName(clientInfoField))
            info = location;
        return Error.init;
    }
}

/// Read the value of a request's params `_meta` member. An absent member is empty.
Metadata metadata(scope const(ubyte)[] raw) nothrow @nogc
{
    Metadata value;
    if (raw.length == 0)
        return value;
    Entries fields;
    if (inspect(raw, &fields.read).code != Status.ok)
        return value;
    value.declared = fields.release.present() || fields.capabilities.present() || fields.info.present();
    if (!readString(fields.release.get(raw), value.revisionStorage[], value.length) || value.length == 0)
        return value;
    value.valid = isObject(fields.capabilities.get(raw)) && (!fields.info.present()
            || validImplementation(fields.info.get(raw)));
    return value;
}

bool validImplementation(scope const(ubyte)[] wire) nothrow @nogc
{
    const name = member(wire, "name");
    const release = member(wire, "version");
    char[256] scratch;
    size_t length;
    return name.ok() && release.ok() && readString(name.value.get(wire), scratch[], length)
        && length != 0 && readString(release.value.get(wire), scratch[], length) && length != 0;
}

void writeClientMeta(ref scope JsonWriter output, bool elicitation) nothrow @nogc
{
    append(output, `"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",`);
    append(output, `"io.modelcontextprotocol/clientInfo":{"name":"flint-mcp","version":"1"},`);
    append(output, `"io.modelcontextprotocol/clientCapabilities":`);
    append(output, elicitation ? `{"elicitation":{"form":{}}}}` : `{}}`);
}

void writeInfo(ref scope JsonWriter output, string name, string softwareVersion) nothrow @nogc
{
    append(output, `{"name":`);
    quote(output, name);
    append(output, `,"version":`);
    quote(output, softwareVersion);
    append(output, "}");
}

void endModernResult(ref scope JsonWriter output, string name, string softwareVersion) nothrow @nogc
{
    append(output, `,"_meta":{"io.modelcontextprotocol/serverInfo":`);
    writeInfo(output, name, softwareVersion);
    append(output, "}}}");
}
