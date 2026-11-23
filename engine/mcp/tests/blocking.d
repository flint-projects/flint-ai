module flint.engine.mcp.blocking_test;

import flint.arena : RequestArena, Status;
import flint.conc : Context;
import flint.engine.mcp : BlockingToolResult, McpOptions, McpServer, McpTool, registerMcp;
import flint.engine.mcp.internal.blocking : BlockingRunner;
import flint.engine.mcp.internal.registry : Registry;
import flint.validate : NotBlank;

@safe:

private struct Word
{
    @NotBlank
    string word;
}

private final class Shouter
{
    size_t calls;

    @McpTool("shout", "Upper-case a word, allocating on the managed worker", true, true)
    BlockingToolResult shout(Word input)
    {
        import std.uni : toUpper;

        calls++;
        if (input.word == "fail")
            throw new Exception("the tool refused " ~ input.word);
        return BlockingToolResult(toUpper(input.word), `{"length":` ~ (cast(char)('0' + input.word.length)) ~ "}");
    }
}

@("a blocking tool decodes, validates and runs on the managed worker, and its failures stay values")
unittest
{
    Registry registry;
    auto provider = new Shouter;
    assert(registry.add(provider).code == Status.ok);
    assert(registry.hasBlocking());
    const tool = registry.findTool("shout");
    assert(tool.blocking !is null && tool.action is null);
    const position = registry.toolPosition("shout");
    auto runner = new BlockingRunner;
    assert(runner.start(4096, (size_t at) @safe nothrow => registry.blockingAt(at)).code == Status.ok);
    scope (exit)
        runner.stop();

    const ok = runner.run(position, cast(const(ubyte)[]) `{"word":"flint"}`);
    assert(!ok.badArguments && !ok.result.isError);
    assert(ok.result.text == "FLINT" && ok.result.structuredJson == `{"length":5}`);

    const invalid = runner.run(position, cast(const(ubyte)[]) `{"word":""}`);
    assert(invalid.badArguments);
    const malformed = runner.run(position, cast(const(ubyte)[]) `{"word":`);
    assert(malformed.badArguments);

    const thrown = runner.run(position, cast(const(ubyte)[]) `{"word":"fail"}`);
    assert(thrown.result.isError && thrown.result.text == "the tool refused fail");

    ubyte[8192] large = '"';
    assert(runner.run(position, large[]).result.isError);
    assert(provider.calls == 2);
}

@("the server starts the managed worker with the first blocking tool and stops it on close")
unittest
{
    McpServer server;
    McpOptions options;
    options.name = "blocking-test";
    options.versionString = "1";
    assert(server.open(options).code == Status.ok);
    auto provider = new Shouter;
    assert(registerMcp(server, provider).code == Status.ok);
    Context context;
    assert(server.close(context).code == Status.ok);
}
