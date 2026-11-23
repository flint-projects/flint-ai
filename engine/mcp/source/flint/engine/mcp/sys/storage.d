/// Exclusive byte storage reserved for an MCP transport.
module flint.engine.mcp.sys.storage;

import core.stdc.stdlib : free, malloc;

@safe:

// SAFETY: The caller reserves a bounded byte-only allocation and owns its sole storage slice.
package(flint.engine.mcp) ubyte[] reserveStorage(size_t size) @trusted nothrow @nogc
{
    if (size == 0)
        return null;
    auto memory = cast(ubyte*) malloc(size);
    return memory is null ? null : memory[0 .. size];
}

// SAFETY: The owner frees exactly its allocation after request and transport borrowers return.
package(flint.engine.mcp) void releaseStorage(ref ubyte[] storage) @trusted nothrow @nogc
{
    if (storage !is null)
    {
        free(storage.ptr);
        storage = null;
    }
}
