/// The managed worker that runs blocking MCP tools, so the protocol path stays `nothrow @nogc`.
///
/// The protocol worker copies a call's arguments into storage the runner owns, publishes the call, and waits
/// cooperatively; the managed worker decodes, validates and runs the tool, which may allocate and throw, and
/// publishes its owned result. One call is in flight at a time.
module flint.engine.mcp.internal.blocking;

import core.atomic : atomicLoad, atomicStore, cas;
import flint.arena : Error, Status;
import flint.conc : Background, Deadline, startManagedBackground;
import flint.conc.wait : waitUntil;
import flint.engine.mcp.types : BlockingToolResult;

@safe:
package(flint.engine.mcp):

/// One blocking call's outcome.
struct BlockingInvocation
{
    /// What the tool returned.
    BlockingToolResult result;
    /// The arguments did not decode or validate against the tool's DTO.
    bool badArguments;
}

/// A registered blocking tool: decode, validate and run.
alias BlockingAction = BlockingInvocation delegate(scope const(char)[] arguments) @safe nothrow;

/// Finds the blocking tool registered at a position; used on the managed worker only.
alias BlockingLookup = BlockingAction delegate(size_t position) @safe nothrow;

private enum State : int
{
    idle,
    claimed,
    requested,
    done
}

/// Runs blocking tools on one managed worker thread.
final class BlockingRunner
{
    private Background worker;
    private shared int state;
    private shared bool stopping;
    private shared bool running;
    private ubyte[] arguments;
    private size_t length;
    private size_t position;
    private BlockingLookup lookup;
    private BlockingInvocation outcome;

    /// Reserve argument storage of `maximum` bytes and start the worker, which finds tools through `tools`.
    Error start(size_t maximum, BlockingLookup tools)
    {
        lookup = tools;
        arguments = new ubyte[maximum];
        const started = startManagedBackground(&loop, worker);
        if (started.code == Status.ok)
            atomicStore(running, true);
        return started;
    }

    /// Run the tool registered at `tool` with a copy of `input`, waiting until it returns.
    BlockingInvocation run(size_t tool, scope const(ubyte)[] input) nothrow @nogc
    {
        if (!atomicLoad(running) || input.length > arguments.length)
            return BlockingInvocation(BlockingToolResult(input.length > arguments.length
                    ? "MCP tool arguments exceed the blocking-call limit" : "blocking MCP tools are not running",
                    null, true));
        while (!cas(&state, cast(int) State.idle, cast(int) State.claimed))
            pause();
        arguments[0 .. input.length] = input[];
        length = input.length;
        position = tool;
        atomicStore(state, cast(int) State.requested);
        while (atomicLoad(state) != State.done)
            pause();
        auto finished = outcome;
        outcome = BlockingInvocation.init;
        atomicStore(state, cast(int) State.idle);
        return finished;
    }

    /// Stop the worker after any call in flight and join it.
    void stop() nothrow @nogc
    {
        if (!atomicLoad(running))
            return;
        atomicStore(stopping, true);
        worker.join();
        atomicStore(running, false);
    }

    private void loop() nothrow
    {
        for (;;)
        {
            if (atomicLoad(state) == State.requested)
            {
                auto action = lookup(position);
                outcome = action is null ? BlockingInvocation(BlockingToolResult("unknown blocking MCP tool",
                        null, true)) : action(cast(const(char)[]) arguments[0 .. length]);
                atomicStore(state, cast(int) State.done);
            }
            else if (atomicLoad(stopping))
                return;
            else
                pause();
        }
    }
}

private void pause() nothrow @nogc
{
    waitUntil(Deadline(Deadline.afterMillis(0).monotonicNanoseconds + 50_000));
}
