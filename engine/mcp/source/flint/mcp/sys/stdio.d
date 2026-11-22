/// Linux stdio descriptors and subprocess ownership.
module flint.mcp.sys.stdio;

import core.stdc.errno : EAGAIN, ECHILD, EINTR, EPIPE, errno;
import core.sys.posix.fcntl : O_CLOEXEC, fcntl;
import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
import core.sys.posix.signal : SIG_BLOCK, SIG_SETMASK, SIGKILL, SIGPIPE, SIGTERM, kill,
    pthread_sigmask, sigaddset, sigemptyset, sigismember, sigpending, sigset_t, sigtimedwait;
import core.sys.posix.sys.wait : WNOHANG, waitpid;
import core.sys.posix.time : timespec;
import core.sys.posix.unistd : _exit, close, dup2, execve, fork, read, write;
import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.mcp.types : McpProcessOptions;

@safe:
package(flint.mcp):

private extern (C) nothrow @nogc
{
    int pipe2(ref int[2], int);
    long syscall(long, ...);
}

// std.string.toStringz without importing std.string (and std.uni): an empty string yields the address of a
// NUL-terminated literal, anything else a fresh NUL-terminated copy.
// SAFETY: The returned pointer addresses a GC copy that nothing else references, or a string literal.
private immutable(char)* toStringz(scope const(char)[] text) @trusted pure nothrow
{
    if (text.length == 0)
        return "".ptr;
    auto copy = new char[text.length + 1];
    copy[0 .. text.length] = text[];
    copy[text.length] = 0;
    return cast(immutable(char)*) copy.ptr;
}

struct Child
{
    int input = -1;
    int output = -1;
    int diagnostic = -1;
    private int process = -1;

    @disable this(this);

    Error open(McpProcessOptions options)
    {
        if (process > 0 || !validProcess(options))
            return Error(Status.invalidArgument, "invalid MCP child process options");
        const path = options.executable.toStringz();
        auto argv = new const(char)*[options.arguments.length + 2];
        auto env = new const(char)*[options.environment.length + 1];
        argv[0] = path;
        foreach (index, argument; options.arguments)
            argv[index + 1] = argument.toStringz();
        foreach (index, setting; options.environment)
            env[index] = setting.toStringz();
        return launch(path, argv, env);
    }

    // The three CLOEXEC pipes and copied argv/env vectors stay owned through fork.
    // SAFETY: On failure all pipes close. The child uses POSIX calls, then exec or _exit without unwinding.
    @trusted nothrow @nogc private Error launch(scope const(char)* path, scope const(char)*[] argv,
            scope const(char)*[] env)
    {
        int[2] incoming = [-1, -1];
        int[2] outgoing = [-1, -1];
        int[2] errors = [-1, -1];
        scope (exit)
        {
            foreach (ref descriptor; incoming)
                retire(descriptor);
            foreach (ref descriptor; outgoing)
                retire(descriptor);
            foreach (ref descriptor; errors)
                retire(descriptor);
        }
        if (!makePipe(incoming) || !makePipe(outgoing) || !makePipe(errors))
            return Error(Status.ioError, "unable to prepare MCP child stdio");
        const pid = fork();
        if (pid == 0)
        {
            if (dup2(incoming[0], 0) < 0 || dup2(outgoing[1], 1) < 0 || dup2(errors[1], 2) < 0)
                _exit(126);
            // close_range(3, UINT_MAX, 0) is syscall 436 on the supported Linux architectures.
            if (syscall(436L, 3U, uint.max, 0U) < 0)
                _exit(126);
            execve(path, argv.ptr, env.ptr);
            _exit(127);
        }
        if (pid < 0)
            return Error(Status.ioError, "unable to start MCP child");
        process = pid;
        input = incoming[1];
        output = outgoing[0];
        diagnostic = errors[0];
        incoming[1] = -1;
        outgoing[0] = -1;
        errors[0] = -1;
        return Error.init;
    }

    Error stop(ref Context context) nothrow @nogc
    {
        if (process <= 0)
            return Error.init;
        retire(input);
        const grace = boundedDeadline(context, 250);
        if (!waitFor(grace))
        {
            signal(process, SIGTERM);
            const terminated = boundedDeadline(context, 250);
            if (!waitFor(terminated))
            {
                signal(process, SIGKILL);
                const killed = boundedDeadline(context, 1000);
                if (!waitFor(killed))
                    return Error(Status.timedOut, "MCP child process still awaits reap");
            }
        }
        retire(output);
        retire(diagnostic);
        return Error.init;
    }

    private bool waitFor(Deadline deadline) nothrow @nogc
    {
        for (;;)
        {
            if (reaped(process))
            {
                process = -1;
                return true;
            }
            if (Deadline.afterMillis(0).monotonicNanoseconds >= deadline.monotonicNanoseconds)
                return false;
            drain(diagnostic, 5);
        }
    }
}

private bool validProcess(scope McpProcessOptions options) pure nothrow @nogc
{
    if (options.executable.length == 0 || options.executable[0] != '/'
            || options.arguments.length > 128 || options.environment.length > 128 || !boundedString(options.executable))
        return false;
    foreach (argument; options.arguments)
    {
        if (!boundedString(argument))
            return false;
    }
    foreach (index, setting; options.environment)
    {
        const prefix = environmentName(setting);
        if (!boundedString(setting) || prefix == 0)
            return false;
        foreach (earlier; options.environment[0 .. index])
        {
            if (prefix == environmentName(earlier) && earlier[0 .. prefix] == setting[0 .. prefix])
                return false;
        }
    }
    return true;
}

private size_t environmentName(scope const(char)[] setting) pure nothrow @nogc
{
    foreach (index, character; setting)
    {
        if (character == '=')
            return index;
    }
    return 0;
}

private bool boundedString(scope const(char)[] value) pure nothrow @nogc
{
    if (value.length > 4_096)
        return false;
    foreach (character; value)
    {
        if (character == '\0')
            return false;
    }
    return true;
}

private Deadline boundedDeadline(ref scope Context context, ulong duration) nothrow @nogc
{
    auto earliest = Deadline.afterMillis(duration);
    if (context.deadline().monotonicNanoseconds < earliest.monotonicNanoseconds)
        earliest = context.deadline();
    return earliest;
}

// SAFETY: New descriptors are owned by the caller and kept above the standard streams.
private bool makePipe(ref int[2] descriptors) @trusted nothrow @nogc
{
    if (pipe2(descriptors, O_CLOEXEC) != 0)
        return false;
    foreach (ref descriptor; descriptors)
    {
        if (descriptor >= 3)
            continue;
        enum duplicateCloseOnExec = 1030;
        const moved = fcntl(descriptor, duplicateCloseOnExec, 3);
        if (moved < 0)
            return false;
        retire(descriptor);
        descriptor = moved;
    }
    return true;
}

// SAFETY: Only the descriptor owner calls close, retires its integer, and never retries Linux close.
private void retire(ref int descriptor) @trusted nothrow @nogc
{
    if (descriptor >= 0)
    {
        close(descriptor);
        descriptor = -1;
    }
}

// SAFETY: The positive PID belongs to the sole reaping owner and cannot recycle before waitpid.
private void signal(int process, int value) @trusted nothrow @nogc
{
    if (process > 0)
        kill(process, value);
}

// SAFETY: Pass the owned positive PID and omit the status buffer. No other caller reaps this child.
private bool reaped(int process) @trusted nothrow @nogc
{
    const status = waitpid(process, null, WNOHANG);
    return status == process || (status < 0 && errno == ECHILD);
}

// SAFETY: poll borrows exactly two descriptors and consumes only a bounded stack diagnostic buffer.
private Result!bool ready(int file, int diagnostic, short event, int millis) @trusted nothrow @nogc
{
    pollfd[2] watching = [pollfd(file, event, 0), pollfd(diagnostic, POLLIN, 0)];
    const checked = poll(watching.ptr, watching.length, millis);
    if (checked < 0 && errno != EINTR)
        return Result!bool(false, Error(Status.ioError, "MCP pipe poll failed"));
    if (watching[1].revents & POLLIN)
    {
        ubyte[4096] discard;
        read(diagnostic, discard.ptr, discard.length);
    }
    return Result!bool(watching[0].revents != 0);
}

private void drain(int diagnostic, int millis) nothrow @nogc
{
    ready(-1, diagnostic, 0, millis);
}

private Error waitReady(int file, int diagnostic, short event, ref scope Context context) nothrow @nogc
{
    if (file < 0)
        return Error(Status.conflict, "MCP pipe is closed");
    for (;;)
    {
        const checked = context.check();
        if (checked.code != Status.ok)
            return checked;
        const current = ready(file, diagnostic, event, 5);
        if (!current.ok() || current.value)
            return current.error;
    }
}

// SAFETY: read synchronously borrows only output's bounded mutable bytes.
private long readInto(int file, scope ubyte[] output) @trusted nothrow @nogc
{
    return read(file, output.ptr, output.length);
}

Result!size_t readPipe(int file, int diagnostic, scope ubyte[] output, ref scope Context context) nothrow @nogc
{
    if (!output.length)
        return Result!size_t(0, Error(Status.invalidArgument, "empty MCP read buffer"));
    for (;;)
    {
        const readable = waitReady(file, diagnostic, POLLIN, context);
        if (readable.code != Status.ok)
            return Result!size_t(0, readable);
        const count = readInto(file, output);
        if (count >= 0)
            return Result!size_t(cast(size_t) count);
        if (errno != EINTR && errno != EAGAIN)
            return Result!size_t(0, Error(Status.ioError, "MCP pipe read failed"));
    }
}

// Write borrows the bounded input synchronously. It never retains a stack reference.
// SAFETY: The caller blocks only SIGPIPE in its own mask, consumes new SIGPIPE, then restores its mask.
private long writeFrom(int file, scope const(ubyte)[] input) @trusted nothrow @nogc
{
    sigset_t blocked;
    sigset_t previous;
    sigset_t pending;
    if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGPIPE) != 0 || pthread_sigmask(SIG_BLOCK,
            &blocked, &previous) != 0)
    {
        errno = EPIPE;
        return -1;
    }
    if (sigpending(&pending) != 0)
    {
        pthread_sigmask(SIG_SETMASK, &previous, null);
        errno = EPIPE;
        return -1;
    }
    const pendingBefore = sigismember(&pending, SIGPIPE) == 1;
    const sent = write(file, input.ptr, input.length);
    const failure = errno;
    if (sent < 0 && failure == EPIPE && !pendingBefore)
    {
        timespec immediate;
        sigtimedwait(&blocked, null, &immediate);
    }
    pthread_sigmask(SIG_SETMASK, &previous, null);
    errno = failure;
    return sent;
}

Error writePipe(int file, int diagnostic, scope const(ubyte)[] input, ref scope Context context) nothrow @nogc
{
    while (input.length)
    {
        const writable = waitReady(file, diagnostic, POLLOUT, context);
        if (writable.code != Status.ok)
            return writable;
        enum atomicPipeBytes = 4096;
        const limit = input.length < atomicPipeBytes ? input.length : atomicPipeBytes;
        const sent = writeFrom(file, input[0 .. limit]);
        if (sent > 0)
            input = input[cast(size_t) sent .. $];
        else if (sent == 0 || (errno != EINTR && errno != EAGAIN))
            return Error(Status.ioError, "MCP pipe write failed");
    }
    return Error.init;
}
