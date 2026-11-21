/// Isolated 2025-11-25 initialization and optional HTTP session state.
module flint.mcp.legacy;

import flint.arena : Error, Status;
import flint.conc : fillSecureRandom;
import flint.mcp.jsonrpc : append, isObject, isString, malformed, member, readString;
import flint.mcp.modern : validImplementation;
import flint.serde.json_write : JsonWriter;

@safe:
package(flint.mcp):

enum legacyRevision = "2025-11-25";

enum LegacyPhase : ubyte
{
    initial,
    awaitingInitialized,
    ready
}

struct SessionKey
{
    char[32] text;

    Error generate() nothrow @nogc
    {
        ubyte[16] nonce;
        const status = fillSecureRandom(nonce[]);
        if (status.code != Status.ok)
            return status;
        enum alphabet = "0123456789abcdef";
        foreach (index, byteValue; nonce)
        {
            text[index * 2] = alphabet[byteValue >> 4];
            text[index * 2 + 1] = alphabet[byteValue & 0xf];
        }
        return Error.init;
    }
}

struct LegacySession
{
    SessionKey key;
    LegacyPhase phase;

    bool recognizes(scope const(char)[] name) const scope pure nothrow @nogc
    {
        return phase != LegacyPhase.initial && name == key.text[];
    }
}

Error validateInitialize(scope const(ubyte)[] params) nothrow @nogc
{
    const revision = member(params, "protocolVersion");
    const capabilities = member(params, "capabilities");
    const info = member(params, "clientInfo");
    char[64] name;
    size_t length;
    if (!revision.ok() || !capabilities.ok() || !info.ok()
            || !readString(revision.value.get(params), name[], length) || length == 0
            || !isObject(capabilities.value.get(params)) || !validImplementation(info.value.get(params)))
        return malformed("invalid legacy initialize parameters");
    return Error.init;
}

bool initialized(scope const(ubyte)[] result) nothrow @nogc
{
    const revision = member(result, "protocolVersion");
    const capabilities = member(result, "capabilities");
    const info = member(result, "serverInfo");
    return revision.ok() && isString(revision.value.get(result), legacyRevision)
        && capabilities.ok() && isObject(capabilities.value.get(result)) && info.ok()
        && validImplementation(info.value.get(result));
}

void writeInitialize(ref scope JsonWriter output) nothrow @nogc
{
    append(output, `"protocolVersion":"2025-11-25","capabilities":{},`);
    append(output, `"clientInfo":{"name":"flint-mcp","version":"1"}`);
}
