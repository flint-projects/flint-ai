module app;

import replay : measure, record;

@safe:

private size_t parse(scope const(ubyte)[] stream) nothrow @nogc
{
    if ((stream.length % record.length) != 0)
        return 0;
    size_t bytes;
    foreach (offset; 0 .. stream.length / record.length)
    {
        const field = stream[offset * record.length .. (offset + 1) * record.length];
        if (field != cast(const(ubyte)[]) record)
            return 0;
        bytes += 56;
    }
    return bytes;
}

/// Run the fixed-envelope reference on request.
int main(string[] args)
{
    return measure!parse(args);
}
