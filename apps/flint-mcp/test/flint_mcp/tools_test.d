module flint_mcp.tools_test;

import flint_mcp.tools : FlintTools, Query;

@safe:

@("a tool returns the command's JSON document and records the call")
unittest
{
    import std.file : exists, readText, remove, tempDir;
    import std.path : buildPath;

    const log = buildPath(tempDir(), "flint-mcp-tools-test.jsonl");
    if (exists(log))
        remove(log);
    // `echo` stands in for flint: its output is the arguments, so the call shape is visible.
    auto tools = new FlintTools("/bin/echo", log);
    const result = tools.searchApi(Query("config load", 3));
    assert(!result.isError);
    assert(result.text == "docs config load --limit 3 --json\n");
    assert(result.structuredJson.length == 0);
    import std.algorithm.searching : startsWith;

    assert(readText(log).startsWith(
            `{"tool":"search_api","arguments":["docs","config","load","--limit","3"],` ~ `"exit_code":0,"millis":`));
    remove(log);
}

@("a failing command is a tool error, not a protocol error")
unittest
{
    auto tools = new FlintTools("/bin/false", null);
    assert(tools.run("check", ["check"]).isError);
    auto missing = new FlintTools("/nonexistent/flint", null);
    assert(missing.run("check", ["check"]).isError);
}
