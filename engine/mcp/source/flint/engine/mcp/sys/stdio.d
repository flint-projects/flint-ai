/// Linux, macOS and Windows stdio pipes and subprocess ownership.
module flint.engine.mcp.sys.stdio;

import flint.arena : Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.engine.mcp.types : McpProcessOptions;

@safe:
package(flint.engine.mcp):

private bool validProcess(scope McpProcessOptions options) pure nothrow @nogc
{
    if (options.executable.length == 0 || !absolutePath(options.executable)
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

version (Windows)
{
    import core.stdc.stdint : intptr_t;
    import core.sys.windows.winbase : CloseHandle, CreatePipe, GetExitCodeProcess, INFINITE, PeekNamedPipe,
        ReadFile, SetHandleInformation, Sleep, TerminateProcess, WaitForSingleObject, WriteFile;
    import core.sys.windows.windef : BOOL, DWORD, HANDLE, TRUE;
    import core.sys.windows.winbase : WAIT_OBJECT_0;
    import core.sys.windows.winerror : ERROR_BROKEN_PIPE;
    import core.sys.windows.winbase : GetLastError;

    // ADR-026: the child starts with CreateProcessW and inherits only its three pipe ends. The parent keeps
    // C runtime descriptors over its pipe handles, so the framing code above this module is unchanged.
    // Readiness comes from PeekNamedPipe, and writes use PIPE_NOWAIT, which accepts what fits and never blocks.
    private enum short POLLIN = 1;
    private enum short POLLOUT = 4;
    private enum uint pipeBytes = 64 * 1024;
    private enum uint handleFlagInherit = 1; // HANDLE_FLAG_INHERIT
    private enum uint pipeNoWait = 1; // PIPE_NOWAIT
    private enum uint unicodeEnvironment = 0x400; // CREATE_UNICODE_ENVIRONMENT
    private enum uint noWindow = 0x08000000; // CREATE_NO_WINDOW
    private enum uint extendedStartup = 0x00080000; // EXTENDED_STARTUPINFO_PRESENT
    private enum uint useStdHandles = 0x100; // STARTF_USESTDHANDLES
    private enum size_t handleListAttribute = 0x20002; // PROC_THREAD_ATTRIBUTE_HANDLE_LIST

    private struct StartupInfoEx
    {
        uint cb;
        wchar* reserved;
        wchar* desktop;
        wchar* title;
        uint x, y, width, height, columns, rows, fill, flags;
        ushort show, reserved2;
        ubyte* reserved3;
        HANDLE input, output, error;
        void* attributes;
    }

    private struct ProcessInformation
    {
        HANDLE process, thread;
        uint processId, threadId;
    }

    private extern (Windows) @system nothrow @nogc
    {
        BOOL CreateProcessW(const(wchar)*, wchar*, void*, void*, BOOL, DWORD, void*,
                const(wchar)*, StartupInfoEx*, ProcessInformation*);
        BOOL InitializeProcThreadAttributeList(void*, DWORD, DWORD, size_t*);
        BOOL UpdateProcThreadAttribute(void*, DWORD, size_t, void*, size_t, void*, size_t*);
        void DeleteProcThreadAttributeList(void*);
        BOOL SetNamedPipeHandleState(HANDLE, DWORD*, DWORD*, DWORD*);
    }

    private extern (C) @system nothrow @nogc
    {
        int _open_osfhandle(intptr_t, int);
        intptr_t _get_osfhandle(int);
        int _close(int);
    }

    private enum int binary = 0x8000; // _O_BINARY
    private enum int readOnly = 0; // _O_RDONLY
    private enum int writeOnly = 1; // _O_WRONLY

    /// "C:\..." or "C:/..." or a UNC path "\\server\share\...".
    private bool absolutePath(scope const(char)[] path) pure nothrow @nogc
    {
        if (path.length >= 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/'))
            return (path[0] | 0x20) >= 'a' && (path[0] | 0x20) <= 'z';
        return path.length >= 3 && path[0] == '\\' && path[1] == '\\';
    }

    /// One argument of a CreateProcess command line, quoted as the Microsoft C runtime parses it.
    private void appendArgument(ref wchar[] line, scope const(char)[] argument) @safe pure
    {
        import std.utf : byWchar;

        if (line.length)
            line ~= ' ';
        bool plain = argument.length != 0;
        foreach (character; argument)
            plain &= character != ' ' && character != '\t' && character != '"';
        if (plain)
        {
            foreach (unit; argument.byWchar)
                line ~= unit;
            return;
        }
        line ~= '"';
        size_t slashes;
        foreach (unit; argument.byWchar)
        {
            if (unit == '\\')
            {
                ++slashes;
                continue;
            }
            // Backslashes are literal unless a quote follows, in which case each one doubles.
            foreach (_; 0 .. (unit == '"' ? 2 * slashes + 1 : slashes))
                line ~= '\\';
            slashes = 0;
            line ~= unit;
        }
        foreach (_; 0 .. 2 * slashes)
            line ~= '\\';
        line ~= '"';
    }

    /// The UTF-16 environment block: the explicit entries, plus SystemRoot, which Windows itself needs to start
    /// most programs (Winsock fails without it). Entries are NUL-separated and the block ends with two NULs.
    private wchar[] environmentBlock(scope const(string)[] entries) @safe
    {
        import std.process : environment;
        import std.uni : sicmp;
        import std.utf : byWchar;

        wchar[] block;
        bool rooted;
        foreach (entry; entries)
        {
            rooted |= environmentName(entry) == "SystemRoot".length && sicmp(entry[0 .. 10], "SystemRoot") == 0;
            foreach (unit; entry.byWchar)
                block ~= unit;
            block ~= '\0';
        }
        const root = environment.get("SystemRoot", null);
        if (!rooted && root.length)
        {
            foreach (unit; ("SystemRoot=" ~ root).byWchar)
                block ~= unit;
            block ~= '\0';
        }
        block ~= '\0';
        return block;
    }

    struct Child
    {
        int input = -1;
        int output = -1;
        int diagnostic = -1;
        private HANDLE process;

        @disable this(this);

        Error open(McpProcessOptions options)
        {
            import std.utf : toUTF16z;

            if (process !is null || !validProcess(options))
                return Error(Status.invalidArgument, "invalid MCP child process options");
            wchar[] line;
            appendArgument(line, options.executable);
            foreach (argument; options.arguments)
                appendArgument(line, argument);
            line ~= '\0';
            return launch(options.executable.toUTF16z, line, environmentBlock(options.environment));
        }

        // The pipes are created non-inheritable; only the child's three ends are marked inheritable and named
        // in the handle list, so no other handle of this process leaks into the child.
        // SAFETY: Every created handle is closed on failure. The attribute list and vectors are live locals or
        // GC arrays for the duration of CreateProcessW, which copies them.
        @trusted nothrow private Error launch(const(wchar)* path, scope wchar[] line, scope const(wchar)[] env)
        {
            HANDLE[2] incoming, outgoing, errors; // [read, write]
            scope (exit)
                foreach (handle; [incoming[0], outgoing[1], errors[1]])
                    if (handle !is null)
                        CloseHandle(handle);
            if (!CreatePipe(&incoming[0], &incoming[1], null, pipeBytes) || !CreatePipe(&outgoing[0],
                    &outgoing[1], null, pipeBytes) || !CreatePipe(&errors[0], &errors[1], null, pipeBytes))
                return closeAll(incoming[1], outgoing[0], errors[0]);
            HANDLE[3] inherited = [incoming[0], outgoing[1], errors[1]];
            foreach (handle; inherited)
                if (!SetHandleInformation(handle, handleFlagInherit, handleFlagInherit))
                    return closeAll(incoming[1], outgoing[0], errors[0]);
            ProcessInformation started;
            if (!createChild(path, line, env, inherited, started))
                return closeAll(incoming[1], outgoing[0], errors[0]);
            CloseHandle(started.thread);
            DWORD mode = pipeNoWait;
            SetNamedPipeHandleState(incoming[1], &mode, null, null);
            process = started.process;
            input = _open_osfhandle(cast(intptr_t) incoming[1], writeOnly | binary);
            output = _open_osfhandle(cast(intptr_t) outgoing[0], readOnly | binary);
            diagnostic = _open_osfhandle(cast(intptr_t) errors[0], readOnly | binary);
            return Error.init;
        }

        // SAFETY: Closes only the parent's ends this launch created and still owns.
        private static Error closeAll(HANDLE first, HANDLE second, HANDLE third) @trusted nothrow @nogc
        {
            foreach (handle; [first, second, third])
                if (handle !is null)
                    CloseHandle(handle);
            return Error(Status.ioError, "unable to start MCP child");
        }

        // SAFETY: The attribute list lives in a local buffer sized by the first query and is deleted on every
        // path; the handle array outlives CreateProcessW, which copies it.
        @trusted nothrow @nogc private static bool createChild(const(wchar)* path,
                scope wchar[] line, scope const(wchar)[] env, ref HANDLE[3] inherited, out ProcessInformation started)
        {
            // The OS fills the attribute list through `attributes`.
            ubyte[256] storage;
            size_t size = storage.length;
            void* attributes = &storage[0];
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, &size))
                return false;
            scope (exit)
                DeleteProcThreadAttributeList(attributes);
            if (!UpdateProcThreadAttribute(attributes, 0, handleListAttribute, inherited.ptr,
                    inherited.sizeof, null, null))
                return false;
            StartupInfoEx startup;
            startup.cb = StartupInfoEx.sizeof;
            startup.flags = useStdHandles;
            startup.input = inherited[0];
            startup.output = inherited[1];
            startup.error = inherited[2];
            startup.attributes = attributes;
            enum DWORD creation = unicodeEnvironment | noWindow | extendedStartup;
            return CreateProcessW(path, line.ptr, null, null, TRUE, creation, cast(void*) env.ptr,
                    null, &startup, &started) != 0;
        }

        Error stop(ref Context context) nothrow @nogc
        {
            if (process is null)
                return Error.init;
            retire(input);
            if (!waitFor(boundedDeadline(context, 500)))
            {
                // Windows has no SIGTERM for a console child; closing its input was the polite request.
                terminate(process);
                if (!waitFor(boundedDeadline(context, 1000)))
                    return Error(Status.timedOut, "MCP child process still awaits reap");
            }
            retire(output);
            retire(diagnostic);
            return Error.init;
        }

        private bool waitFor(Deadline deadline) nothrow @nogc
        {
            for (;;)
            {
                if (exited(process))
                {
                    release(process);
                    return true;
                }
                if (Deadline.afterMillis(0).monotonicNanoseconds >= deadline.monotonicNanoseconds)
                    return false;
                drain(diagnostic, 5);
            }
        }
    }

    // SAFETY: The owned process handle is live until release.
    private bool exited(HANDLE process) @trusted nothrow @nogc
    {
        return WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
    }

    // SAFETY: Only the owner terminates its live, unreleased process handle.
    private void terminate(HANDLE process) @trusted nothrow @nogc
    {
        TerminateProcess(process, 1);
    }

    // SAFETY: The owner releases its exited process handle exactly once.
    private void release(ref HANDLE process) @trusted nothrow @nogc
    {
        CloseHandle(process);
        process = null;
    }

    // SAFETY: Only the descriptor owner closes it, which also closes its pipe handle, and retires the integer.
    private void retire(ref int descriptor) @trusted nothrow @nogc
    {
        if (descriptor >= 0)
        {
            cast(void) _close(descriptor);
            descriptor = -1;
        }
    }

    // SAFETY: _get_osfhandle returns the live handle behind an owned descriptor, or -1.
    private HANDLE handleOf(int descriptor) @trusted nothrow @nogc
    {
        const value = descriptor < 0 ? -1 : _get_osfhandle(descriptor);
        return value == -1 ? null : cast(HANDLE) value;
    }

    /// Bytes waiting in the pipe, or -1 at end of stream (the writer closed) or on an error.
    // SAFETY: PeekNamedPipe writes only the local count and copies no data.
    private long available(HANDLE pipe) @trusted nothrow @nogc
    {
        DWORD count;
        if (!PeekNamedPipe(pipe, null, 0, null, &count, null))
            return -1;
        return count;
    }

    // SAFETY: ReadFile writes at most the bounded local buffer, which a peek showed is available.
    private void discard(HANDLE pipe) @trusted nothrow @nogc
    {
        const waiting = available(pipe);
        if (waiting <= 0)
            return;
        ubyte[4096] sink;
        DWORD read;
        ReadFile(pipe, sink.ptr, waiting < sink.length ? cast(DWORD) waiting : sink.length, &read, null);
    }

    private Result!bool ready(int file, int diagnostic, short event, int millis) nothrow @nogc
    {
        const deadline = Deadline.afterMillis(millis);
        auto pipe = handleOf(file);
        auto errors = handleOf(diagnostic);
        for (;;)
        {
            if (errors !is null)
                discard(errors);
            // A nonblocking pipe accepts whatever fits, so a writer is always ready to try.
            if (pipe !is null && (event == POLLOUT || available(pipe) != 0))
                return Result!bool(true);
            if (Deadline.afterMillis(0).monotonicNanoseconds >= deadline.monotonicNanoseconds)
                return Result!bool(false);
            pause();
        }
    }

    // SAFETY: Sleep borrows nothing.
    private void pause() @trusted nothrow @nogc
    {
        Sleep(1);
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

    /// Bytes read, 0 at end of stream, or -1 on an error.
    // SAFETY: ReadFile writes at most the bytes a peek showed waiting, within output's bounded mutable slice.
    private long readInto(int file, scope ubyte[] output) @trusted nothrow @nogc
    {
        auto pipe = handleOf(file);
        const waiting = available(pipe);
        if (waiting < 0)
            return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
        DWORD read;
        const wanted = waiting < output.length ? cast(DWORD) waiting : cast(DWORD) output.length;
        if (!ReadFile(pipe, output.ptr, wanted, &read, null))
            return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
        return read;
    }

    Result!size_t readPipe(int file, int diagnostic, scope ubyte[] output, ref scope Context context) nothrow @nogc
    {
        if (!output.length)
            return Result!size_t(0, Error(Status.invalidArgument, "empty MCP read buffer"));
        const readable = waitReady(file, diagnostic, POLLIN, context);
        if (readable.code != Status.ok)
            return Result!size_t(0, readable);
        const count = readInto(file, output);
        if (count < 0)
            return Result!size_t(0, Error(Status.ioError, "MCP pipe read failed"));
        return Result!size_t(cast(size_t) count);
    }

    /// Bytes accepted (0 while the pipe is full), or -1 once the reader has gone.
    // SAFETY: WriteFile reads only the bounded input; the handle is switched to PIPE_NOWAIT so it never blocks.
    private long writeFrom(int file, scope const(ubyte)[] input) @trusted nothrow @nogc
    {
        auto pipe = handleOf(file);
        DWORD mode = pipeNoWait;
        SetNamedPipeHandleState(pipe, &mode, null, null);
        DWORD written;
        if (!WriteFile(pipe, input.ptr, cast(DWORD) input.length, &written, null))
            return -1;
        return written;
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
            if (sent < 0)
                return Error(Status.ioError, "MCP pipe write failed");
            if (sent > 0)
                input = input[cast(size_t) sent .. $];
            else
                drain(diagnostic, 1);
        }
        return Error.init;
    }
}
else
{
    import core.stdc.errno : EAGAIN, ECHILD, EINTR, EPIPE, errno;
    import core.sys.posix.fcntl : fcntl;
    import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
    import core.sys.posix.signal : SIG_BLOCK, SIG_SETMASK, SIGKILL, SIGPIPE, SIGTERM, kill,
        pthread_sigmask, sigaddset, sigemptyset, sigismember, sigpending, sigset_t;
    import core.sys.posix.sys.wait : WNOHANG, waitpid;
    import core.sys.posix.time : timespec;
    import core.sys.posix.unistd : _exit, close, dup2, execve, fork, read, write;

    version (OSX)
    {
        // Darwin has no pipe2, close_range, F_DUPFD_CLOEXEC 1030 or sigtimedwait (ADR-024). Children start
        // through posix_spawn with POSIX_SPAWN_CLOEXEC_DEFAULT, and the input pipe never raises SIGPIPE.
        import core.sys.posix.spawn : posix_spawn, posix_spawn_file_actions_adddup2,
            posix_spawn_file_actions_destroy, posix_spawn_file_actions_init,
            posix_spawn_file_actions_t, posix_spawnattr_destroy,
            posix_spawnattr_init, posix_spawnattr_setflags, posix_spawnattr_t;

        private enum short spawnCloexecDefault = 0x4000; // POSIX_SPAWN_CLOEXEC_DEFAULT
        private enum int duplicateCloseOnExec = 67; // F_DUPFD_CLOEXEC
        private enum int setNoSigPipe = 73; // F_SETNOSIGPIPE
    }
    else
    {
        import core.sys.posix.signal : sigtimedwait;

        private extern (C) nothrow @nogc
        {
            int pipe2(ref int[2], int);
            long syscall(long, ...);
        }

        private enum int duplicateCloseOnExec = 1030;
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

    /// An absolute POSIX path.
    private bool absolutePath(scope const(char)[] path) pure nothrow @nogc
    {
        return path.length != 0 && path[0] == '/';
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
        @trusted nothrow @nogc private Error launch(scope const(char)* path,
                scope const(char)*[] argv, scope const(char)*[] env)
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
            version (OSX)
            {
                if (fcntl(incoming[1], setNoSigPipe, 1) != 0)
                    return Error(Status.ioError, "unable to prepare MCP child stdio");
                const pid = spawnChild(path, argv, env, incoming[0], outgoing[1], errors[1]);
            }
            else
                const pid = forkChild(path, argv, env, incoming[0], outgoing[1], errors[1]);
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

        // SAFETY: The child uses POSIX calls, then exec or _exit without unwinding.
        private static int forkChild(scope const(char)* path, scope const(char)*[] argv,
                scope const(char)*[] env, int input, int output, int errors) @trusted nothrow @nogc
        {
            const pid = fork();
            if (pid == 0)
            {
                if (dup2(input, 0) < 0 || dup2(output, 1) < 0 || dup2(errors, 2) < 0)
                    _exit(126);
                version (linux)
                {
                    // close_range(3, UINT_MAX, 0) is syscall 436 on the supported Linux architectures.
                    if (syscall(436L, 3U, uint.max, 0U) < 0)
                        _exit(126);
                }
                execve(path, argv.ptr, env.ptr);
                _exit(127);
            }
            return pid;
        }

        version (OSX)
        {
            // A failed exec is reported here, before any child exists, instead of as exit status 127.
            // posix_spawn borrows the terminated path and vectors only during the call.
            // SAFETY: The attribute and action objects are local and destroyed on every path.
            private static int spawnChild(scope const(char)* path, scope const(char)*[] argv,
                    scope const(char)*[] env, int input, int output, int errors) @trusted nothrow @nogc
            {
                import core.sys.posix.sys.types : pid_t;

                posix_spawnattr_t attributes;
                posix_spawn_file_actions_t actions;
                if (posix_spawnattr_init(&attributes) != 0)
                    return -1;
                scope (exit)
                    posix_spawnattr_destroy(&attributes);
                if (posix_spawn_file_actions_init(&actions) != 0)
                    return -1;
                scope (exit)
                    posix_spawn_file_actions_destroy(&actions);
                pid_t pid;
                if (posix_spawnattr_setflags(&attributes, spawnCloexecDefault) != 0
                        || posix_spawn_file_actions_adddup2(&actions,
                            input, 0) != 0 || posix_spawn_file_actions_adddup2(&actions, output, 1) != 0
                        || posix_spawn_file_actions_adddup2(&actions, errors, 2) != 0 || posix_spawn(&pid,
                            path, &actions, &attributes, cast(char**) argv.ptr, cast(char**) env.ptr) != 0)
                    return -1;
                return pid;
            }
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

    // SAFETY: New descriptors are owned by the caller and kept above the standard streams.
    private bool makePipe(ref int[2] descriptors) @trusted nothrow @nogc
    {
        version (OSX)
        {
            import core.sys.posix.fcntl : FD_CLOEXEC, F_SETFD;
            import core.sys.posix.unistd : pipe;

            // Darwin has no pipe2; children start with POSIX_SPAWN_CLOEXEC_DEFAULT, so none inherits these.
            if (pipe(descriptors) != 0)
                return false;
            foreach (descriptor; descriptors)
                if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0)
                    return false;
        }
        else
        {
            import core.sys.posix.fcntl : O_CLOEXEC;

            if (pipe2(descriptors, O_CLOEXEC) != 0)
                return false;
        }
        foreach (ref descriptor; descriptors)
        {
            if (descriptor >= 3)
                continue;
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
        // Darwin raises SIGPIPE at the process; the input pipe is marked F_SETNOSIGPIPE at launch instead.
        version (OSX)
            return write(file, input.ptr, input.length);
        else
        {
            sigset_t blocked;
            sigset_t previous;
            sigset_t pending;
            if (sigemptyset(&blocked) != 0 || sigaddset(&blocked, SIGPIPE) != 0
                    || pthread_sigmask(SIG_BLOCK, &blocked, &previous) != 0)
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
}
