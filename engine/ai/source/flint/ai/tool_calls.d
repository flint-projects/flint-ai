/// Request-local accumulation of interleaved provider tool arguments.
module flint.ai.tool_calls;

import flint.ai.types : ChatEvent, EventConsumer, EventKind;
import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.serde.json_visit : JsonMemberName, visitJsonObject;

@safe:

private enum blockSize = 4096;
private enum argumentLimit = 1024 * 1024;
private immutable string[16] labels = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15"
];
package(flint.ai) enum maxArgumentBlocks = argumentLimit / blockSize + labels.length - 1;
private alias Arena = RequestArena;

package(flint.ai) struct ArgumentBlock
{
    uint next;
    uint used;
    ubyte[blockSize] bytes;
}

private struct Call
{
    char[128] key;
    char[128] id;
    char[64] name;
    ushort keyLength;
    ushort idLength;
    ushort nameLength;
    uint first;
    uint last;
    uint bytes;
    bool completed;
}

private Error malformed(string message) pure nothrow @nogc
{
    return Error(Status.invalidArgument, message);
}

private Error exhausted() pure nothrow @nogc
{
    return Error(Status.resourceExhausted, "provider tool argument capacity reached");
}

package(flint.ai) struct ToolCalls
{
@safe:
nothrow:
@nogc:

    private ArgumentBlock[] blocks;
    private Call[labels.length] calls;
    private uint declared;
    private uint filled;
    private size_t stored;
    private bool emitting;

    @disable this(this);
    @disable void opAssign(ToolCalls value);

    this(return scope ArgumentBlock[] blocks)
    {
        this.blocks = blocks.length > maxArgumentBlocks ? blocks[0 .. maxArgumentBlocks] : blocks;
    }

    private uint find(scope const(char)[] key) const scope
    {
        foreach (index, ref entry; calls[0 .. declared])
            if (entry.key[0 .. entry.keyLength] == key)
                return cast(uint) index;
        return uint.max;
    }

    Error associate(scope const(char)[] key, scope const(char)[] id, scope const(char)[] name) scope
    {
        if (emitting)
            return Error(Status.conflict, "recursive tool event");
        if (key.length == 0 || key.length > 128 || id.length == 0 || id.length > 128
                || name.length == 0 || name.length > 64)
            return malformed("provider tool identity is missing or too long");
        const existing = find(key);
        if (existing != uint.max)
        {
            const entry = &calls[existing];
            return entry.id[0 .. entry.idLength] == id && entry.name[0 .. entry.nameLength] == name
                ? Error.init : malformed("provider redefined a tool call");
        }
        foreach (ref other; calls[0 .. declared])
            if (other.id[0 .. other.idLength] == id)
                return malformed("provider reused a tool call ID");
        if (declared == calls.length)
            return exhausted();
        auto entry = &calls[declared++];
        entry.keyLength = cast(ushort) key.length;
        entry.idLength = cast(ushort) id.length;
        entry.nameLength = cast(ushort) name.length;
        entry.key[0 .. key.length] = key;
        entry.id[0 .. id.length] = id;
        entry.name[0 .. name.length] = name;
        return Error.init;
    }

    Error append(scope const(char)[] key, scope const(ubyte)[] input) scope
    {
        const index = find(key);
        if (emitting || index == uint.max || calls[index].completed)
            return malformed("provider argument delta refers to an inactive tool call");
        return appendTo(calls[index], input);
    }

    private Error appendTo(ref scope Call call, scope const(ubyte)[] input) scope
    {
        if (input.length > argumentLimit - stored)
            return exhausted();
        const tailRoom = call.last == 0 ? 0 : blockSize - blocks[call.last - 1].used;
        const remaining = input.length > tailRoom ? input.length - tailRoom : 0;
        if ((remaining + blockSize - 1) / blockSize > blocks.length - filled)
            return exhausted();
        call.bytes += cast(uint) input.length;
        stored += input.length;
        while (input.length != 0)
        {
            if (call.last == 0 || blocks[call.last - 1].used == blockSize)
            {
                const link = ++filled;
                blocks[link - 1].next = 0;
                blocks[link - 1].used = 0;
                if (call.last == 0)
                    call.first = link;
                else
                    blocks[call.last - 1].next = link;
                call.last = link;
            }
            auto tail = &blocks[call.last - 1];
            const open = blockSize - tail.used;
            const used = input.length < open ? input.length : open;
            tail.bytes[tail.used .. tail.used + used] = input[0 .. used];
            tail.used += cast(uint) used;
            input = input[used .. $];
        }
        return Error.init;
    }

    Result!Buffer finish(scope const(char)[] key, scope const(ubyte)[] finalArgs,
            ref scope RequestArena arena, out uint index) scope
    {
        index = find(key);
        if (emitting || index == uint.max)
            return Result!Buffer(Buffer.init, malformed("provider completed an unknown tool call"));
        auto call = &calls[index];
        if (call.completed)
        {
            index = uint.max;
            return Result!Buffer.init;
        }
        if (call.bytes == 0)
        {
            const appended = appendTo(*call, finalArgs.length == 0 ? cast(const(ubyte)[]) "{}" : finalArgs);
            if (appended.code != Status.ok)
                return Result!Buffer(Buffer.init, appended);
        }

        const data = arena.allocate(call.bytes);
        if (!data.ok)
            return data;
        const copied = copyArguments(*call, data.value, arena);
        if (copied.code != Status.ok)
            return Result!Buffer(Buffer.init, copied);
        const checked = validateArguments(data.value, finalArgs, arena);
        return Result!Buffer(data.value, checked);
    }

    Error publish(uint index, Buffer data, ref scope RequestArena arena, scope EventConsumer consume,
            Buffer providerState = Buffer.init, bool providerAssignedId = true) scope
    {
        if (index == uint.max)
            return Error.init;
        if (index >= declared || consume is null)
            return malformed("invalid tool output consumer");
        auto call = &calls[index];
        const id = arena.copyIn(cast(const(ubyte)[]) call.id[0 .. call.idLength]);
        if (!id.ok)
            return id.error;
        const name = arena.copyIn(cast(const(ubyte)[]) call.name[0 .. call.nameLength]);
        if (!name.ok)
            return name.error;
        ChatEvent event = ChatEvent(EventKind.toolDelta, data, labels[index], 0, 0, id.value, name.value);
        event.providerState = providerState;
        event.providerAssignedId = providerAssignedId;
        call.completed = true;
        emitting = true;
        scope (exit)
            emitting = false;
        return consume(event, arena);
    }

    bool completed() scope const
    {
        foreach (ref tool; calls[0 .. declared])
            if (!tool.completed)
                return false;
        return true;
    }

    private Error copyArguments(ref scope const Call call, Buffer buffer, ref scope RequestArena arena) scope
    {
        const result = arena.write(buffer, (scope ubyte[] output) @safe nothrow @nogc {
            size_t position;
            for (uint link = call.first; link != 0; link = blocks[link - 1].next)
            {
                const node = &blocks[link - 1];
                output[position .. position + node.used] = node.bytes[0 .. node.used];
                position += node.used;
            }
        });
        return Error(result);
    }
}

private Error validateArguments(Buffer buffer, scope const(ubyte)[] finalArgs, ref scope Arena arena) nothrow @nogc
{
    Error result;
    const visited = arena.read(buffer, (scope const(ubyte)[] json) @safe nothrow @nogc {
        if (finalArgs.length != 0 && json != finalArgs)
            result = malformed("final tool arguments differ from the streamed arguments");
        else
            result = visitJsonObject(json, (scope JsonMemberName, scope const(ubyte)[]) @safe nothrow @nogc {
                return Error.init;
            });
    });
    return visited == Status.ok ? result : Error(visited, "tool arguments are no longer available");
}
