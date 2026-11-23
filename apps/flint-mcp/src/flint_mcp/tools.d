/// The tools of `flint mcp` (ADR-021 section 6): each runs the matching `flint` command with `--json` in the
/// client's project directory and returns its document, as text and as structured content.
module flint_mcp.tools;

import flint.engine.mcp : BlockingToolResult, McpTool;
import flint.validate : NotBlank;

@safe:

/// search_api input.
struct Query
{
    /// Words, or a qualified name.
    @NotBlank
    string query;
    /// Maximum symbols.
    uint limit = 10;
}

/// get_symbol input.
struct SymbolName
{
    /// Qualified name, such as flint.config.load.
    @NotBlank
    string name;
}

/// get_example input.
struct Topic
{
    /// Topic words.
    @NotBlank
    string topic;
    /// Maximum examples.
    uint limit = 5;
}

/// explain_error input.
struct Code
{
    /// Diagnostic code, such as FLINT-E0401.
    @NotBlank
    string code;
}

/// Tools without input.
struct Nothing
{
}

/// resolved_config input.
struct Profile
{
    /// Configuration profile.
    string profile = "dev";
}

/// generate input.
struct Component
{
    /// entity, repository, service, controller, config, migration or agents.
    @NotBlank
    string kind;
    /// PascalCase name (empty for agents).
    string name;
    /// Only show what would be written.
    bool plan;
}

/// build input.
struct Build
{
    /// dev, release, size or sanitize.
    string profile = "dev";
}

/// test input.
struct Test
{
    /// dmd, ldc or both; empty for the test profile's compiler.
    string compiler;
}

/// The tools.
final class FlintTools
{
    private string flint;
    private string log;

    /// `flint` is the executable to run; `log` names a JSON Lines call log, or is empty.
    this(string flint, string log)
    {
        this.flint = flint;
        this.log = log;
    }

    /// search_api.
    @McpTool("search_api", "Search the exact API of the pinned Flint libraries: signatures, documentation and tested "
            ~ "examples. Ask this instead of guessing an API.", true, true)
    BlockingToolResult searchApi(Query input)
    {
        import std.array : split;
        import std.conv : to;

        return run("search_api", ["docs"] ~ input.query.split ~ ["--limit", input.limit.to!string]);
    }

    /// get_symbol.
    @McpTool("get_symbol",
            "One symbol by qualified name, with its signature, documentation and tested examples", true, true)
    BlockingToolResult getSymbol(SymbolName input)
    {
        return run("get_symbol", ["docs", input.name]);
    }

    /// get_example.
    @McpTool("get_example", "Compiled, tested examples for a topic, and matching complete applications", true, true)
    BlockingToolResult getExample(Topic input)
    {
        import std.array : split;
        import std.conv : to;

        return run("get_example", ["examples"] ~ input.topic.split ~ [
            "--limit", input.limit.to!string
        ]);
    }

    /// explain_error.
    @McpTool("explain_error", "The long explanation of a FLINT-Ennnn diagnostic, with a correct example", true, true)
    BlockingToolResult explainError(Code input)
    {
        return run("explain_error", ["explain", input.code]);
    }

    /// describe_project.
    @McpTool("describe_project", "The project's manifest, layout checks and dependency tree", true, true)
    BlockingToolResult describeProject(Nothing)
    {
        return run("describe_project", ["deps", "tree"]);
    }

    /// resolved_config.
    @McpTool("resolved_config",
            "Every resolved configuration key for a profile, with its value and source file", true, true)
    BlockingToolResult resolvedConfig(Profile input)
    {
        return run("resolved_config", ["config", "--profile", input.profile]);
    }

    /// dependency_graph.
    @McpTool("dependency_graph", "The resolved dependency graph: Flint packages, repository modules, DUB and native "
            ~ "packages, with versions", true, true)
    BlockingToolResult dependencyGraph(Nothing)
    {
        return run("dependency_graph", ["deps", "tree"]);
    }

    /// generate.
    @McpTool("generate", "Write the canonical shape of a component (entity, repository, service, controller, config, "
            ~ "migration) or refresh AGENTS.md; set plan to only show it", false, true)
    BlockingToolResult generate(Component input)
    {
        string[] arguments = ["generate", input.kind];
        if (input.name.length)
            arguments ~= input.name;
        if (input.plan)
            arguments ~= "--plan";
        return run("generate", arguments);
    }

    /// build.
    @McpTool("build",
            "Build the project with a canonical profile; errors come with codes, locations and fixes", false, true)
    BlockingToolResult build(Build input)
    {
        return run("build", ["build", "--profile", input.profile]);
    }

    /// test.
    @McpTool("test", "Build and run the project's tests", false, true)
    BlockingToolResult test(Test input)
    {
        return run("test", input.compiler.length ? ["test", "--compiler", input.compiler] : ["test"]);
    }

    /// check.
    @McpTool("check", "Every check CI runs: lock, layout, safety rules, formatting, lint and clang-tidy", true, true)
    BlockingToolResult check(Nothing)
    {
        return run("check", ["check"]);
    }

    /// Run `flint <arguments> --json`; the document is the result, and a nonzero exit marks it an error.
    BlockingToolResult run(string tool, string[] arguments)
    {
        import std.datetime.stopwatch : StopWatch;
        import flint.conc : Context;
        import flint.os : ProcessOptions, osRun = run;

        StopWatch watch;
        watch.start();
        Context context;
        ProcessOptions options;
        options.maxCaptureBytes = 12 << 20;
        const result = osRun(context, [flint] ~ arguments ~ "--json", options);
        const millis = watch.peek.total!"msecs";
        if (!result.ok)
        {
            record(tool, arguments, -1, millis);
            return BlockingToolResult("flint could not run: " ~ result.error.message, null, true);
        }
        const document = (cast(const(char)[]) result.value.stdoutBytes).idup;
        record(tool, arguments, result.value.code, millis);
        const structured = document.length && document[0] == '{' ? document : null;
        return BlockingToolResult(document.length ? document
                : (cast(const(char)[]) result.value.stderrBytes).idup, structured, result.value.code != 0);
    }

    private void record(string tool, scope const string[] arguments, int exitCode, long millis)
    {
        import std.file : append;
        import flint.serde.owned : serialize;

        if (log.length == 0)
            return;
        static struct Call
        {
            string tool;
            const(string)[] arguments;
            int exit_code;
            long millis;
        }

        const call = Call(tool, arguments, exitCode, millis);
        const line = serialize(call);
        if (line.ok)
            append(log, line.value ~ "\n");
    }
}
