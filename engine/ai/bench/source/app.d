module app;

import flint.ai.sse : SseParser;
import flint.arena : Error, Status;
import replay : measure, record;

@safe:

private size_t parse(scope const(ubyte)[] stream) nothrow @nogc
{
    ubyte[64] line, event;
    scope parser = SseParser(line[], event[]);
    size_t bytes;
    const parsed = parser.feed(stream, (scope const(char)[] kind, scope const(ubyte)[] data) @safe nothrow @nogc {
        if (kind != "message" || data != cast(const(ubyte)[]) record[6 .. $ - 2])
            return Error(Status.invalidArgument);
        bytes += data.length;
        return Error.init;
    });
    return parsed.code == Status.ok && parser.finish().code == Status.ok ? bytes : 0;
}

/// Run the parser workload on request.
int main(string[] args)
{
    return measure!parse(args);
}
