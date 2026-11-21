/// Representative memory stream of 64-byte SSE envelopes.
module replay;

import core.memory : GC;
import core.time : MonoTime;
import std.stdio : writefln;

@safe:

/// One text delta and its standard SSE field prefix and delimiter.
enum record = "data: " ~ q{{"type":"response.output_text.delta","delta":"12345678"}} ~ "\n\n";
static assert(record.length == 64);

/// Reuse a complete 8 KiB input block over a fixed 100 MiB trial.
int measure(alias parse)(scope const string[] args)
{
    if (args.length != 2 || args[1] != "--measure")
        return args.length == 1 ? 0 : 2;
    ubyte[8 * 1024] block;
    foreach (offset; 0 .. block.length / record.length)
        block[offset * record.length .. (offset + 1) * record.length] = cast(const(ubyte)[]) record;
    enum byteCount = 100 * 1024 * 1024;
    const allocated = GC.stats().allocatedInCurrentThread;
    const start = MonoTime.currTime;
    ulong observed;
    foreach (_; 0 .. byteCount / block.length)
        observed += parse(block[]);
    const elapsed = (MonoTime.currTime - start).total!"nsecs";
    const gcBytes = GC.stats().allocatedInCurrentThread - allocated;
    const expected = (byteCount / record.length) * 56UL;
    if (observed != expected || gcBytes != 0)
        return 1;
    writefln("bytes=%s decoded_bytes=%s elapsed_ns=%s gc_bytes=%s", byteCount, observed, elapsed, gcBytes);
    return 0;
}
