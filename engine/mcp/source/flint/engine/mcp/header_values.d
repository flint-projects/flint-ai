/// Canonical HTTP field value encoding for modern MCP.
module flint.engine.mcp.header_values;

@safe:
package(flint.engine.mcp):

private enum prefix = "=?base64?";
private enum suffix = "?=";
private enum letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

private bool sentinel(scope const(char)[] raw) pure nothrow @nogc
{
    return raw.length >= prefix.length + suffix.length && raw[0 .. prefix.length] == prefix
        && raw[$ - suffix.length .. $] == suffix;
}

private bool white(char byteValue) pure nothrow @nogc
{
    return byteValue == ' ' || byteValue == '\t';
}

private bool plain(scope const(char)[] raw) pure nothrow @nogc
{
    if (raw.length && (white(raw[0]) || white(raw[$ - 1])))
        return false;
    foreach (byteValue; raw)
    {
        if ((byteValue < ' ' && byteValue != '\t') || byteValue > '~')
            return false;
    }
    return true;
}

bool encodeHeader(scope const(char)[] raw, scope char[] output, out size_t length) pure nothrow @nogc
{
    if (plain(raw) && !sentinel(raw))
    {
        if (raw.length > output.length)
            return false;
        output[0 .. raw.length] = raw;
        length = raw.length;
        return true;
    }
    const encoded = (raw.length / 3 + (raw.length % 3 != 0)) * 4;
    const needed = prefix.length + encoded + suffix.length;
    if (needed > output.length)
        return false;
    output[0 .. prefix.length] = prefix;
    size_t offset = prefix.length;
    for (size_t index; index < raw.length; index += 3)
    {
        const a = cast(ubyte) raw[index];
        const b = index + 1 < raw.length ? cast(ubyte) raw[index + 1] : 0;
        const c = index + 2 < raw.length ? cast(ubyte) raw[index + 2] : 0;
        output[offset++] = letters[a >> 2];
        output[offset++] = letters[(a & 3) * 16 + (b >> 4)];
        output[offset++] = index + 1 < raw.length ? letters[(b & 15) * 4 + (c >> 6)] : '=';
        output[offset++] = index + 2 < raw.length ? letters[c & 63] : '=';
    }
    output[offset .. offset + suffix.length] = suffix;
    length = needed;
    return true;
}

bool matchesHeader(scope const(char)[] header, scope const(char)[] expected) pure nothrow @nogc
{
    if (!plain(header))
        return false;
    if (!sentinel(header))
        return header == expected;
    const encoded = header[prefix.length .. $ - suffix.length];
    if (encoded.length % 4 != 0)
        return false;
    uint scalar;
    uint bits;
    size_t matched;
    size_t encodedEnd;
    foreach (position, digit; encoded)
    {
        if (digit == '=')
        {
            encodedEnd = position;
            break;
        }
        const number = digitValue(digit);
        if (number < 0)
            return false;
        scalar = scalar * 64 + number;
        bits += 6;
        if (bits >= 8)
        {
            bits -= 8;
            if (matched == expected.length || cast(ubyte)(scalar >> bits) != cast(ubyte) expected[matched++])
                return false;
            scalar &= (1U << bits) - 1;
        }
        encodedEnd = position + 1;
    }
    return matched == expected.length && scalar == 0 && validPadding(encoded[encodedEnd .. $], matched);
}

private bool validPadding(scope const(char)[] remaining, size_t length) pure nothrow @nogc
{
    foreach (pad; remaining)
    {
        if (pad != '=')
            return false;
    }
    const padding = length % 3 ? 3 - length % 3 : 0;
    return remaining.length == padding;
}

private int digitValue(char character) pure nothrow @nogc
{
    if (character >= 'A' && character <= 'Z')
        return character - 'A';
    if (character >= 'a' && character <= 'z')
        return character - 'a' + 26;
    if (character >= '0' && character <= '9')
        return character - '0' + 52;
    if (character == '+')
        return 62;
    return character == '/' ? 63 : -1;
}
