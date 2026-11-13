# LuaSH 2.0 design

> **Status.** This is the design that LuaSH 2.0 was built from. It was
> written before the code, for an implementer, which is why it speaks of
> the implementation in the future tense; the work packages of
> [PLAN.md](PLAN.md) landed as pull requests #3 to #14. The `reference/`
> code it mentions was the starting point from the design discussion and
> is no longer in the repository (it is in the git history under
> `handoff/reference/`). The [How it works](how-it-works/architecture.md)
> pages describe what was built and link the sections here to the code.
> `pushenv` and `popenv` came after 2.0: section 3.8 and the paragraphs on
> the environment in sections 4 and 6 describe them as built.

This document is the design for the next version of `sh` (LuaSH). It is
written for an implementer who has not seen the discussion that led to it.
Read it completely before reading `PLAN.md`, which splits the work into
packages that can run in parallel. `reference/` holds the code produced in
the earlier design discussion; it is a starting point, not the deliverable
(see `reference/README.md` for its known defects).

Repository: `github.com/JBlaschke/luash`. Current release: `sh.lua` 1.3.0,
one file, hard dependency on luaposix.

## 1. Goals

1. Split the monolithic `sh.lua` into modules with one responsibility each.
2. Three interchangeable process backends with one contract: luaposix
   (fork/exec), luv (libuv `uv.spawn`), and pure-Lua `io.popen`.
3. Automatic backend choice by platform: POSIX (Linux, macOS, BSD) prefers
   luaposix, Windows and Android prefer luv, everything falls back to popen.
4. `require("posix")` and `require("luv")` are never hard requirements. Each
   is loaded with `pcall(require, ...)` at the point of use, so the library
   loads and works on an interpreter that has neither.
5. A single-file build of the library, `standalone/sh.lua`, for systems where
   luarocks is not an option. A user copies that one file into their project
   and calls `require("sh")`. It is a library, not an executable.
6. A rich command type: build commands and pipelines as data, print them as
   a shell pipeline (`seq 1 10 | wc -l`), run them, and have every result
   remember the pipeline that produced it.
7. A verbose mode that streams child output byte for byte, so progress bars
   from `curl` and `wget` render as they would in a terminal.
8. Keep the public API that `simple-modules` and the existing tests use.
   `simple-modules` vendors `sh.lua` as `opt/lib/sh.lua` and uses:
   `sh.<cmd>(...)`, `sh("bash"){...}`, `sh.command`, `sh.cd`, `sh.pushd`,
   `sh.popd`, `sh.__verbose`, `sh.__raise_errors`, `tostring(result)`,
   table-style flags such as `sh.uname({s=true})`.

Non-goals: Windows is designed for but cannot be tested in the development
environment (no Windows machine); concurrent execution of pipeline stages
(stages run one after another, as today); asynchronous API.

## 2. Module layout

```
sh/
├── init.lua          -- public module: command(), install(), builtins,
│                        config, Result objects
├── command.lua       -- Command and Pipeline types, argument flattening,
│                        shell quoting, rendering (was args.lua)
├── pipe.lua          -- the run path: verbose/trace plumbing over the
│                        backend in use
├── sys.lua           -- platform detection, load_pcall
├── stack.lua         -- LIFO stack used by pushd/popd and pushenv/popenv
└── backend/
    ├── init.lua      -- registry: platform table, selection once, the
    │                    unified interface (run, chdir, getcwd, ...)
    ├── posix.lua     -- luaposix: fork, execp, poll loop; chdir, setenv
    ├── luv.lua       -- luv: uv.spawn, pipes, uv.run("once") loop; chdir,
    │                    setenv
    └── popen.lua     -- io.popen plus temp-file strategies; emulated cd
                         and environment
standalone/sh.lua     -- GENERATED single-file library; never edit by hand
opt/bin/build.lua     -- amalgamation driver (make standalone)
opt/bin/build/amalg.lua -- vendored amalg.lua, copied verbatim from
                         ../simple-templates/opt/bin/build/amalg.lua
tests/test.lua        -- gambiarra suite (extended)
tests/test_command.lua   -- unit tests for sh/command.lua, no processes
tests/test_backend.lua   -- backend contract test: lua tests/test_backend.lua posix
tests/backend_fake.lua   -- minimal contract implementation for development
tests/run_all.sh      -- interpreter x backend matrix
tests/gambiarra.lua   -- vendored test library
rockspec/sh-2.0-1.rockspec
```

`require("sh")` resolves to `sh/init.lua` through the `?/init.lua` entry of
`package.path`. The root `sh.lua` is deleted; `experiments/sh.lua` is a
symlink to it and is deleted too. Dependency direction, no cycles:

```
init -> command, pipe, backend, sys, stack
pipe -> backend
backend -> sys, backend.*
backend.* -> (posix | luv | io.popen), never init/pipe/command
sys  -> nothing
```

## 3. Public API

### 3.1 Unchanged

| Call | Behaviour (unchanged) |
|---|---|
| `sh.name(...)` | run program `name` now, return a Result |
| `sh("name", pre...)`, `sh.command("name", pre...)` | return a function with pre-set arguments |
| `sh.install()` | undefined globals become commands |
| `r:name(...)` | chaining: `r.__input` becomes stdin of `name` |
| `tostring(r)`, `r .. s`, `s .. r` | trimmed stdout, or `O: ... E: ... <code>` when stderr is non-empty |
| `sh.stdout(r)`, `sh.stderr(r)` | the raw fields |
| `sh.cd`, `sh.pushd`, `sh.popd`, `sh.print` | builtins; they pass `__input` through unchanged |
| `sh.PUSHD_STACK` | the pushd stack object |
| `sh.FUNCTIONS` | table of the builtins, consulted by `install()` |
| `sh.__index_ignore_prefix`, `sh.__index_ignore_exact`, `sh.__index_ignore_function` | lists consulted by `install()` |
| `sh.version` | `"Automatic Shell Bindings for Lua / LuaSH 2.0.0"` (keep this format; the test compares the whole string) |
| `{key=value}` tables | become flags, see section 7 |

Dropped: `sh.PIPES`, `sh.launch_pipe_simple`, `sh.collect_pipes` (never
worked: they reference undefined variables).

### 3.2 Configuration

```lua
sh.config = {
    verbose      = false,  -- stream child output live (section 3.7)
    trace        = false,  -- print "+ <pipeline>" to stderr before each run
    raise_errors = true,   -- error() when a command fails (section 3.6)
    backend      = "auto", -- "auto" | "posix" | "luv" | "popen"
    popen        = {       -- options of the popen backend
        strategy = "auto", -- "auto" | "shmem" | "standard" | "basic" | "minimal"
        tmpdir   = nil,    -- root for temp files; nil = platform default
    },
    sink         = nil,    -- function(stream, chunk); replaces io writes in
                           -- verbose mode; stream is "stdout" or "stderr"
}
```

`verbose`, `trace`, `raise_errors` and `sink` are read at every run.
`backend` and `popen` are read when `sh` loads, when a table is assigned to
`sh.config`, and by `sh.set_backend()` (section 3.3); they are never
checked at a run.

`sh.__verbose` and `sh.__raise_errors` stay valid as aliases of
`sh.config.verbose` and `sh.config.raise_errors`, reading and writing. The
module table has no raw field of either name, nor of `config`; its
metatable's `__index` and `__newindex` map the three names onto the
configuration table, so that `sh.config = {...}` is seen: the new table
goes to the run path and the backend it names is selected (an error when
that backend is unavailable, and then nothing changes). Any other
assignment to the module table is a plain `rawset`.

Environment overrides, read once when `sh.backend` loads and only when the
corresponding config value is `"auto"`: `LUASH_BACKEND` (`posix`, `luv`,
`popen`) and `LUASH_POPEN_STRATEGY`. They exist for the test matrix and for
operators; code should use `sh.config` or `sh.set_backend`.

### 3.3 Backend control

```lua
sh.set_backend(name, opts)   -- select now; error if unavailable, and then
                             -- the backend in use is unchanged.
                             -- opts for popen: { strategy = ..., tmpdir = ... }
sh.set_backend()             -- select what sh.config.backend/popen name
sh.backend_name()            -- name of the backend in use
sh.available_backends()      -- e.g. { "posix", "luv", "popen" } in platform order
sh.capabilities()            -- table, see section 5
```

The backend in use is selected once, when `sh` loads (the default of the
platform, section 6.6), and again only by these calls; `sh.config` records
the selection.

### 3.4 Command and Pipeline

Both live in `sh/command.lua` and are exported as `sh.Command` and
`sh.Pipeline`. Capitalised names cannot collide with a program name looked
up through `sh.<name>` (programs are lower case by convention; `cmd` is a
real program on Windows, which is why the constructor is not `sh.cmd`).

```lua
local c = sh.Command("ls", "-l")   -- not executed
c:arg("/tmp", "/var")              -- append positional arguments; returns c
c:flag("color", "auto")            -- append "--color=auto"; ordered; returns c
c:flag("a")                        -- append "-a"
c:flag("l", false)                 -- appends nothing
c:input("data")                    -- stdin for this command; a Result works too
c:argv()                           -- new table { "ls", "-l", "/tmp", ... }
tostring(c)                        -- "ls -l /tmp /var --color=auto -a"
c:run()                            -- Result (same path as sh.ls(...))
c:pipe(sh.Command("wc", "-l"))     -- Pipeline

local p = sh.Pipeline(c1, c2, c3)  -- or c1:pipe(c2):pipe(c3)
p:pipe(c4)                         -- append; returns p
p:commands()                       -- new array of the Command stages
tostring(p)                        -- "ls -l | grep foo | wc -l"
p:run()                            -- runs stages left to right, feeding
                                   -- stdout of one into stdin of the next;
                                   -- returns the Result of the last stage
```

`Command(name, ...)` accepts exactly what `sh.name(...)` accepts (section 7),
so `sh.Command("stat", "/bin", {format = "%a"})` works. `:flag()` is the
ordered alternative to the `{key = value}` table.

On Lua 5.3 and newer, `__bor` is defined on both types so that
`sh.Command("ls") | sh.Command("wc", "-l")` builds a Pipeline. Define the
metamethod unconditionally; older interpreters ignore it.

Rendering rules (`tostring`): arguments are joined by single spaces. An
argument that matches the Lua pattern `^[%w%-%._/=:@%%+,]+$` is printed
bare; any other argument, including the empty string, is single-quoted with
embedded `'` written as `'\''`. Stages of a Pipeline are joined with ` | `.
Where a stage received the output of several commands at once (for example
`wc(seq(1, 10), seq(20, 25), "-l")`), those commands render as a group:
`{ seq 1 10; seq 20 25; } | wc -l`. Literal stdin given as `{__input = s}`
is not rendered.

Both types are plain tables with a metatable; `getmetatable(c).__name` is
`"sh.Command"` or `"sh.Pipeline"` so other modules can recognise them without
a dependency.

`sh/command.lua` never requires `sh.init` or `sh.pipe`. `:run()` calls a
runner that `init.lua` installs at load time with
`command.set_runner(function(cmd, input) ... end)`; the runner returns a
Result. Before a runner is installed `:run()` raises
`"sh.command: no runner installed (require 'sh' first)"`, so the unit tests
of `sh/command.lua` never start a process.

### 3.5 Result objects

Every executed command and every builtin returns a Result: a table with
raw fields `__input`, `__stdout`, `__stderr`, `__exitcode`, `__signal` and
the new `__pipeline`, with a metatable providing `__index` (falls back to the
`sh` module, which is what makes `r:grep(...)` work), `__tostring` and
`__concat`. All six fields always exist (`__pipeline` may be `nil` for a
Result built from literal input only).

`__pipeline` is the Pipeline that produced the Result: for
`sh.seq(1, 10):wc("-l")` the `wc` Result has
`tostring(r.__pipeline) == "seq 1 10 | wc -l"`. A builtin (`cd`, `pushd`,
`popd`, `pushenv`, `popenv`, `print`) passes `__pipeline` through
unchanged; builtins are not processes and never appear in a rendering.

Exit mapping (unchanged): `__exitcode` is the exit status when the child
exited, `127` when it was killed; `__signal` is the signal number when it
was killed, `0` otherwise.

### 3.6 Errors

With `raise_errors` on, a command whose child did not exit with status 0
raises `error(message, 2)` where `message` is the trimmed stderr when it is
non-empty, otherwise `"<rendered pipeline>: exit status N"` or
`"<rendered pipeline>: killed by signal N"`. With `raise_errors` off the
Result is returned and nothing is raised. Builtins never raise; they report
through `__exitcode` and `__stderr` as today.

A program that cannot be started (not on PATH, not executable) is reported
by every backend the same way: `__exitcode == 127` and a non-empty
`__stderr` naming the program. It is not a Lua error. Today the posix path
raises an assertion inside the forked child and the README documents that
traceback; the new README must document the 127 convention instead.

### 3.7 Verbose and trace

The current verbose mode (`print(buf:sub(1, -2))` on each 4 KiB chunk)
drops the last byte of every chunk, inserts a newline after every chunk,
and sends stderr to stdout. Measured with `seq 1 1500`, the number `1041`
straddled a chunk boundary and was printed as the two lines `10` and `1`.
A curl-style progress bar written as `\r 33% done` (one `write` per update,
no newline) came out as one line per update with the last character
missing, on stdout. This is the "funny / truncated output" seen in
`simple-modules`.

New behaviour:

- `verbose = true`: every chunk of the child's stdout is written unchanged
  to `io.stdout`, every chunk of stderr to `io.stderr`, each followed by a
  flush. No newline is added, no byte is removed. Carriage returns and
  escape sequences pass through, so progress bars animate in a terminal.
- `sink = function(stream, chunk)`: when set, verbose output goes to the
  sink instead of the io handles. Tests use this; `simple-modules` can use
  it to prefix lines with the step name.
- `trace = true`: before a stage runs, `"+ " .. tostring(pipeline) .. "\n"`
  is written to `io.stderr` (or to `sink("trace", line)` when a sink is
  set), where the pipeline is every stage up to and including this one,
  like `set -x` in a shell.
- Invariant for every backend and strategy: the concatenation of all chunks
  passed to the stdout callback equals `Result.__stdout` byte for byte; same
  for stderr. Backends that cannot stream (popen with stderr in a temp file)
  deliver that stream in one chunk at the end.

### 3.8 Environment variables

Added after 2.0, on the pattern of `pushd` and `popd`.

| Call | Behaviour |
|---|---|
| `sh.pushenv(...)` | builtin: change environment variables for the commands that follow, and push what they were |
| `sh.popenv()` | builtin: put the variables of the last `pushenv` back |
| `sh.PUSHENV_STACK` | the stack object; one frame per `pushenv` |

Arguments of `pushenv`, read by `command.parse_env`: a string is
`"NAME=value"`, split at the first `=`; a table gives one variable per
string key, where a string or a number is the value and `false` removes
the variable, and its array entries are read as arguments again; `nil` and
`false` are skipped; a variable named twice gets the later value; a Result
passes through as for every builtin. Unlike in section 7, every string key
is a name, also one starting with `_`. A string without `=`, an empty
name, a NUL byte in a name or value, and `true` or a table as a value are
argument errors, raised at the caller like those of a command.

The variables change one by one through the backend (section 4), in byte
order of the names, so that the order does not depend on the table. A
frame lists `{ name, value }` with the value each variable had before,
`false` for one that was not set. When the backend refuses a variable, the
ones already changed are put back, no frame is pushed, and the Result
reports `pushenv: <name>: <reason>` with `__exitcode` 1: a `pushenv` takes
effect whole or not at all. `popenv` restores the top frame in reverse
order, goes on past a variable that fails and reports the first such
failure; with an empty stack it reports
`popenv: the environment stack is empty`. A `pushenv` without variables
pushes an empty frame, so that the calls stay paired.

Decided against: `sh.with_env(vars):cmd(...)`, because nothing says where
along a chain the variables stop applying, and a public `sh.getenv`,
because a command answers for what the commands get, and the registry's
`getenv` does for code that needs it. A block form `with_env(vars, f)`
that pops under an error as well can be built on the two builtins; the
how-it-works page shows it.

## 4. Backend contract

Each backend is a module returning a table with this shape. Nothing else is
public. Backends never require `sh.init`, `sh.pipe` or `sh.command`. Every
function is required: the registry (section 6.6) does not select a module
that lacks one, and `tests/test_backend.lua` checks for them.

```lua
B.name = "posix"              -- "posix" | "luv" | "popen"

function B.available()        -- -> true | false, reason
-- Cheap, no side effects beyond pcall(require, "posix" / "luv"). For popen:
-- pcall(io.popen, "exit 0") succeeds (interpreters built without popen
-- raise "'popen' not supported").

function B.capabilities()     -- -> table, see section 5

function B.configure(opts)    -- popen only; others accept and ignore it

function B.run(argv, input, opts)   -- -> result table

function B.chdir(dir)         -- -> true | nil, reason
function B.getcwd()           -- -> path | nil, reason
-- The working directory of the programs run() starts: posix and luv change
-- the directory of the process (posix.chdir, uv.chdir); popen, which has
-- no chdir, resolves `dir` through the shell, remembers it and enters it
-- at each run (section 6.3). `dir` is a non-empty string, checked by the
-- registry.
```

Two more functions are optional. They are not part of the contract, so
that a backend written for the six above is still selected:

```lua
function B.setenv(name, value) -- -> true | nil, reason; nil removes
function B.getenv(name)        -- -> value | nil
-- The environment of the programs run() starts (section 3.8): posix and
-- luv change the environment of the process; popen, which cannot,
-- remembers the variables and hands them to each run (section 6.3).
-- `name` is a non-empty string without "=" and NUL, `value` a string
-- without NUL or nil; the registry checks both. Without setenv(), the
-- registry answers "backend <name> cannot change the environment";
-- without getenv(), it asks os.getenv.
```

`run` arguments:

- `argv`: array of strings; `argv[1]` is the program, looked up on PATH; the
  rest are passed to the program exactly as given. Only the popen backend
  goes through a shell, and it must quote every element so the program
  receives it verbatim.
- `input`: string, possibly empty. It is written to the child's stdin and
  stdin is then closed, so the child sees EOF. Empty input still gives the
  child a closed or `/dev/null` stdin, never the parent's terminal.
- `opts`: table, may be empty:
  `on_stdout(chunk)` and `on_stderr(chunk)` optional callbacks (section 3.7);
  `cwd` optional directory the child must run in. Every backend honours it
  (posix: `chdir` in the child before `execp`; luv: the `cwd` spawn option;
  popen: a `cd` prefix). The run path never passes it: without it, the
  child runs in the directory of `B.getcwd()`.

`run` result: `{ exitcode = integer, signal = integer, stdout = string,
stderr = string, cause = "exited" | "killed" | "failed" }`. `exitcode` is
always an integer: the exit status, 127 for a child that was killed or
could not be started, and 0 or 1 ("as far as the backend can tell") where
`capabilities().exitcode` is false. `signal` is always an integer, 0 when
the child was not killed or the backend cannot know. `cause == "failed"`
means the program could not be started: then `exitcode == 127` and
`stderr` names the program and the reason; the popen backend cannot tell a
start failure from an exit status of 127 and reports `"exited"`. `run`
raises only for programmer errors (empty `argv`, a non-string element); a
child's failure is never a Lua error at this level.

`tests/backend_fake.lua` implements this contract in a few lines with
`io.popen` and merged stderr; `tests/test_backend.lua <name>` checks any
backend against the contract and is the acceptance test for each backend
package.

## 5. Capabilities

```lua
{
    name            = "popen",     -- backend
    strategy        = "basic",     -- popen only, else nil
    stdin           = true,        -- false for popen "minimal"
    separate_stderr = true,        -- false for popen "minimal" and "basic"
    streaming       = true,        -- chunks arrive while the child runs
    exitcode        = true,        -- false for popen "basic"/"minimal" on
                                   -- Lua 5.1 and LuaJIT (section 6.3)
    signals         = true,        -- false for popen: a killed child is
                                   -- reported as exit status 128 + N
}
```

`sh.capabilities()` returns the active backend's table. The test suite
branches on it: with `separate_stderr == false` stderr text is expected in
`__stdout` and `__stderr` is empty; with `stdin == false` input-dependent
tests are skipped.

## 6. Backend designs

### 6.1 posix (`sh/backend/posix.lua`)

Based on `reference/sh/pipe_posix.lua` with these changes.

- Child side: after `posix.execp(argv[1], args_table)` returns (it only
  returns on failure), write `"sh: <name>: command not found\n"` (or the
  errno text) with `posix.write(2, ...)` and call `posix._exit(127)`. Never
  `assert` or `error` in the child: a Lua error there unwinds through a
  copy of the host program's stack. luaposix 36 accepts the argument table
  form `execp(path, {args...})`; use it.
- Parent side, one poll loop over three descriptors instead of two
  coroutines: `{ [w] = {events = {OUT = true}}, [r] = {events = {IN = true}},
  [e] = {events = {IN = true}} }` with `posix.poll(fds, timeout)`. Set
  `O_NONBLOCK` on `w` with `posix.fcntl(w, posix.F_SETFL, posix.O_NONBLOCK)`.
  When `w` is writable, write the next slice of `input` (64 KiB at most) and
  advance; when all input is written, close `w` and drop it from the set.
  When `r` or `e` is readable, `posix.read(fd, 4096)`; an empty or nil read
  is EOF: close the fd, drop it from the set. Finish when both read fds are
  gone, then `posix.wait(pid)`. This removes the deadlock on inputs larger
  than the kernel pipe buffer (today `posix.write` of the whole input blocks
  before any output is read, so `cat` or `sort` with a 64 KiB input hangs).
- SIGPIPE: with the default disposition, writing to a child that has
  already exited kills the Lua process with status 141 (verified with
  luaposix 36.3 on macOS; `sh.head(big_input, "-c", "1")` is the everyday
  case). Ignore it around the write loop: `posix.signal(posix.SIGPIPE,
  posix.SIG_IGN)` returns the previous handler (measured: the string
  `"SIG_DFL"`, or a function when the host installed one); pass that value
  back to `posix.signal` after `wait`. With it ignored, `posix.write`
  returns `nil, "Broken pipe", posix.EPIPE`: treat that as "stop writing,
  close w" and carry on reading. A non-blocking write may also return
  `nil, msg, posix.EAGAIN`: that means "wait for the next poll".
- `opts.cwd`: `posix.chdir(cwd)` in the child, between `fork` and `execp`;
  on failure write the message to fd 2 and `_exit(127)` like an exec
  failure.
- Verbose: call `opts.on_stdout` / `opts.on_stderr` with each chunk as read.
  No `print`, no `sub(1, -2)`.
- `wait` reports `"exited"`, `"killed"` or `"stopped"`; map `stopped` to
  `killed`.
- Lua 5.1: use `table.unpack or unpack` if unpack is needed at all.
- `B.name = "posix"` (the reference module lacks it, so
  `backend_name()` returned nil for posix).
- `setenv` is `posix.stdlib.setenv(name, value)`, which removes the
  variable for a nil value, and `getenv` is `os.getenv`. The function is
  taken from `posix.stdlib` like `execp` from `posix.unistd`; without it
  `setenv` returns nil and the reason.

### 6.2 luv (`sh/backend/luv.lua`)

Based on `reference/sh/pipe_luv.lua` (version 2, which already fixes a
closure-scope bug and the `uv.run("default")` hang).

- When `uv.spawn` returns `nil, err` (for example `ENOENT: no such file or
  directory`), close the three pipes and return a `cause = "failed"` result
  with `exitcode = 127` and `stderr = argv[1] .. ": " .. err`. Do not
  `error()`.
- Keep the `uv.run("once")` loop until the three completion events (exit,
  stdout EOF, stderr EOF) have fired, then `uv.run("nowait")`. Document in
  the module comment that `run` must not be called from inside a libuv
  callback because the loop is not re-entrant; `sh` is a synchronous API.
- A write error on stdin (child exited early) arrives in the write
  callback; close the pipe and continue. libuv already ignores SIGPIPE.
- Signals: `on_exit(code, signal)` with `signal > 0` is `cause = "killed"`.
- Windows: `uv.spawn` resolves `argv[1]` on PATH and quotes arguments
  itself; nothing platform-specific is needed here.
- Use `opts.cwd` as the `cwd` option of `uv.spawn` when given.
- `setenv` is `uv.os_setenv`, or `uv.os_unsetenv` for a nil value, and
  `getenv` is `uv.os_getenv`, not `os.getenv`: on Windows the C library
  keeps a copy of the environment that `uv.os_setenv` does not change.
  `uv.os_getenv` takes a buffer size; a value that does not fit
  (`ENOBUFS`) is asked for again with a larger one.

### 6.3 popen (`sh/backend/popen.lua`)

Based on `reference/sh/pipe_popen.lua`, keeping the four strategy names and
replacing its temp-file scheme.

Strategies, from most to least capable:

| strategy | stdin | stderr | needs |
|---|---|---|---|
| `shmem` | temp file in a private dir under `/dev/shm` | separate temp file | Linux with writable `/dev/shm` |
| `standard` | temp file in a private dir under the temp root | separate temp file | writable temp root |
| `basic` | `printf '%s' '<input>' \|` on the command line | merged into stdout (`2>&1`) | nothing |
| `minimal` | `</dev/null` (input discarded) | merged | nothing |

`strategy = "auto"` picks the first available in that order. `basic` puts
the input on the command line, where every user of the machine can read it
in `ps` and where it is limited by the argument size limit; the README and
the module comment say so, and `basic` is never chosen automatically when
a file strategy is available. Temp root for `standard`: `config.popen.tmpdir`
or `TMPDIR`, `TMP`, `TEMP`, then `/tmp` (`%TEMP%` on Windows).

Private directory, created once per process on the first use of a file
strategy: `<root>/luash-<pid>-<random>` made with
`os.execute("mkdir -m 700 '<path>'")` (POSIX `mkdir -m`; on Windows plain
`mkdir`, relying on the user's temp directory permissions). `mkdir` is
atomic and fails if the name exists, which is the collision check: on
failure pick a new random suffix and retry (give up after a handful of
tries with a clear error). `<pid>` comes from `io.popen("echo $$")` once
(the subshell's pid is unique at that moment and good enough as a prefix;
on Windows the prefix is omitted);
`<random>` comes from `math.random` after seeding with `os.time()`,
`os.clock()` and the digits of `tostring({})`. The result of `os.execute`
is `true` on Lua 5.2 and newer but the raw status number on Lua 5.1 and
LuaJIT (`0` on success, `768` for exit status 3): test for success with
`r == true or r == 0`. Inside the directory files
are named `in-<n>` and `err-<n>` from a per-process counter, written by
Lua with `io.open(path, "wb")`. Because the directory is fresh and mode
700, no symlink or permission race exists and no `chmod` is needed.
Each `run` removes its two files afterwards, success or failure (pcall).
`B.cleanup_all()` removes the files and the directory; a sentinel with a
`__gc` metamethod calls it when the state closes. Tables take `__gc` on Lua
5.2 and newer only; on Lua 5.1 and LuaJIT use `newproxy(true)`, which
returns a userdata whose metatable may carry `__gc` (measured: `newproxy`
exists on the Homebrew LuaJIT, `__gc` on a table does not fire there). After
a crash the directory may be left behind; its name pattern `luash-*` makes
it safe to delete. The reference code's claim that cleanup
runs on module collection was false; this design makes it true where the
interpreter allows.

Command strings are POSIX `sh` syntax only: every argument single-quoted
(`'` as `'\''`), redirections `< 'in-3' 2> 'err-3'`, merged strategies
`2>&1`, discarded input `</dev/null`, optional prefix `cd '<cwd>' && ` when
`opts.cwd` is given. The string is a single simple command, so the
`set -eu` rule for shell scripts does not apply to it; a test dumps a few
generated strings and runs `shellcheck -s sh` over them when shellcheck is
installed.

Windows variant, selected when `sys.platform() == "windows"`: `cmd.exe`
syntax, `NUL` for `/dev/null`, `cd /d "<cwd>" && `, arguments wrapped in
double quotes with embedded `"` doubled. Best effort: it cannot be tested
here; keep it in one clearly marked function so it can be fixed later.

Emulated `cd`: `io.popen` has no `chdir`, so `B.chdir(dir)` runs
`(cd -P '<current>' && cd -P './<dir>' && pwd -P) 2>/dev/null` through the
shell (`cd /d` and `cd` under cmd.exe), which checks that the directory can
be entered and resolves it; the printed path is remembered, `B.getcwd()`
returns it (else `pwd -P`), and `run` enters it when `opts.cwd` is nil. The
emulated directory applies to the programs this backend runs only, not to
Lua's own `io` functions; the README says so.

Emulated environment: standard Lua cannot set a variable either, so
`B.setenv(name, value)` records the change in a table, and each `run`
applies the table inside the subshell that runs the program:
`unset -v <names> || exit 127;` for the variables to remove, and
`exec env '<NAME>=<value>' ... <argv>` for those to set. The assignments go
through `env` because a shell does not hand every assignment of its own to
a child: bash takes one to `RANDOM` as a seed and refuses one to `UID`.
A value equal to what the process has drops the entry, so that a run
without changes uses the same string as before. `B.getenv` answers with
the recorded value, else `os.getenv`. Limits, which `setenv` reports
instead of running into them: a name is letters, digits and `_`, not
starting with a digit (what `unset -v` takes); `PATH` cannot be removed,
because bash and dash look for a program in the current directory once it
is unset, where `execvp` searches a default path. While a variable is set,
a program name with `=` is a start failure, since `env` would read it as
an assignment. A variable that the shell refuses to unset (bash: an
exported `SHELLOPTS`) fails the run with 127 and the shell's message, like
a directory that cannot be entered. Under cmd.exe the changes become
`set "NAME=value" &` in front of the command, and `setenv` refuses an
empty value and one with `"`, `%` or a line break. The variables that are
set are part of the command line, so the check of its length before
`io.popen` covers them: a run whose line is too long is a start failure.
Like the directory, this environment applies to the programs this backend
runs only, not to Lua's `os.getenv`.

Streaming: read the popen handle with `h:read(4096)` in a loop and pass
each chunk to `on_stdout`. After `h:close()`, read the stderr file and pass
it to `on_stderr` in one chunk.

Exit status. `h:close()` returns `true|nil, "exit"|"signal", code` on Lua
5.2 and newer, but only `true` on Lua 5.1 and on LuaJIT unless it was built
with `LUAJIT_ENABLE_LUA52COMPAT` (measured on the Homebrew LuaJIT: `exit 3`
gives `true`, nothing else). So the file strategies never rely on it:
the command string ends with `; echo "$?" > 'st-<n>'` and the backend reads
the status from that third temp file, on every interpreter. The merged
strategies have no file to write to; they take the status from `h:close()`
where it reports one (feature-detected once at load with
`io.popen("exit 7"):close()`) and otherwise return `exitcode = 0` with
`capabilities().exitcode == false`. A child killed by signal N shows up as
status `128 + N` from the shell; the backend reports that number as
`exitcode`, `signal = 0`, `cause = "exited"`, and `capabilities().signals`
is false. When `h:close()` itself reports `"signal", N` (the popen shell
exec'd the command and was killed in its place), report `exitcode =
128 + N` the same way.

### 6.4 Run path (`sh/pipe.lua`)

`run(argv, input, pipeline)` runs one command through the backend in use
(`sh.backend.current()`). It owns the verbose/trace plumbing: it builds the
`on_stdout` and `on_stderr` callbacks from `sh.config` (sink or io handles
with flush) and writes the trace line. A backend whose
`capabilities().stdin` is false (popen `minimal`) raises
`"sh: backend popen/minimal cannot pass input to <program>"` when it is
given non-empty input, instead of silently discarding it. It reads the
configuration table that `sh/init.lua` hands over with `set_config`, and
selects nothing.

### 6.5 sys (`sh/sys.lua`)

- `platform()`: `"windows"` when `package.config:sub(1, 1) == "\\"` or
  `jit.os == "Windows"`; `"android"` when `ANDROID_ROOT` or `ANDROID_DATA`
  is set in the environment; otherwise `"posix"`.
- `load_pcall(f, ...)` and `loading()`: `pcall` for code that loads or
  probes a library, during which `sh.install()`'s hook leaves undefined
  globals nil (libraries read optional globals to detect features).

### 6.6 Registry (`sh/backend/init.lua`)

The one place that knows the backends. Resolve once, look up, never
re-detect: a backend is loaded, checked against the contract, configured
and asked whether it is available at a selection only, and the selected
module answers every later `run`, `chdir`, `getcwd`, `setenv`, `getenv`
and `capabilities` call through the registry's functions of the same
names. Nothing is probed at a command, a `cd` or a `pushenv`.

```lua
local ORDER = {
    posix   = { "posix", "luv", "popen" },
    windows = { "luv", "popen" },
    android = { "luv", "posix", "popen" },
}
```

`android` prefers luv because processes embedding Lua on Android commonly
ship luv and `fork` inside an app process is unsupported; a Termux-style
userland works with luaposix as the second choice. This order is an
assumption; it is a one-line table to change.

`select(choice, opts)` resolves `choice` by its type, through a lookup
table (`RESOLVE[type(choice)]`): a table of your own is checked against
the contract, configured and asked whether it is available; a name is the
module `sh.backend.<name>`, treated the same; `"auto"` (or nil) is
`LUASH_BACKEND` when set, else the first backend of `ORDER[platform]` that
loads, is complete and is available, each candidate configured with `opts`
first because popen answers for its configured strategy. `opts` are the
popen options, with `LUASH_POPEN_STRATEGY` replacing a strategy of
`"auto"`. A backend that lacks a function of the contract is skipped by
`"auto"` and an error by name, naming what it lacks. A named backend that
is unavailable is an error naming the backend and the reason; no backend
available at all is an error listing every candidate's reason. A failed
selection leaves the backend in use as it was (configured again with its
options, since the attempt may have reconfigured popen). `sh/init.lua`
calls `select` when it loads, inside `pcall`: with no backend available the
module still loads, and the first command raises the recorded reason.

`current()`, `name()`, `capabilities()`, `run(argv, input, opts)`,
`chdir(dir)` and `getcwd()` go to the backend in use; `chdir` checks that
`dir` is a non-empty string. `setenv(name, value)` and `getenv(name)` go
there too when the backend has them (section 4): `setenv` checks its
arguments first and returns nil and a reason for a backend without it,
and `getenv` falls back to `os.getenv`. `available()` lists the platform's backends
that load, are complete and are available with the options of the backend
in use, found once per selection. `preload()` loads the platform's
backends for `sh.install()`. Modules load, are configured and are asked
whether they are available through `sys.load_pcall`.

## 7. Argument flattening (`sh/command.lua`)

Applies to `sh.name(...)`, `sh.Command(name, ...)` and `:arg(...)`.

1. Strings and numbers are positional arguments, in order, converted with
   the original `tostring`.
2. A table with array entries is walked depth first; its entries follow the
   same rules (`sh("bash"){"-c", "type type"}`).
3. A Result (a table with `__stdout`) contributes its `__input` to stdin,
   in order, and its `__pipeline` to provenance. A plain `{__input = s}`
   contributes `s` to stdin. Other `__` fields of such tables are passed
   through for builtins as today (`cd` returns the previous stage's
   stdout, stderr, exit code and signal).
4. String keys not starting with `_` are flags. Keys are visited in sorted
   order, so the output is deterministic (today it depends on table
   layout). One-character keys give `-k`, longer keys give `--key`. Values:
   `true` gives the bare flag; `false` or `nil` gives nothing (today
   `{l = false}` wrongly emits `-l`); a string gives `key=value`, including
   the empty string (`--key=`); a number gives `key=<number>`; anything else
   is an error naming the key. Order-sensitive flags belong in positional
   strings or `:flag()` calls; the README says so.
5. Keys starting with `_` that are not the known `__` fields are ignored.

## 8. Standalone single-file library

`make standalone` runs `opt/bin/build.lua`, which sets `package.path` to
`<repo>/?.lua;<repo>/?/init.lua`, loads `opt/bin/build/amalg.lua` with
`loadfile` and calls it as

```
amalg -o standalone/sh.lua -s sh/init.lua
      sh.command sh.pipe sh.sys sh.stack
      sh.backend.posix sh.backend.luv sh.backend.popen
```

`sh/init.lua` is the main script, so the amalgamated chunk ends with its
`return M`, and `require("sh")` with `package.path` containing
`standalone/?.lua` returns the module; `dofile("standalone/sh.lua")` too.
`posix` and `luv` are not in the module list and are not embedded; amalg
leaves their `require` calls alone and they resolve on the host at run
time, inside `pcall`. Acceptance for the gating requirement:

```bash
lua -e 'package.cpath = ""' tests/test.lua      # neither posix nor luv
```

must pass with the backend resolving to popen, both against `sh/` and
against `standalone/sh.lua`; and `grep -n 'require("posix")\|require("luv")'
standalone/sh.lua` must show every hit on a line containing `pcall`.

The generated file is committed (users copy it from the repository) and is
regenerated, never edited. Model: `../simple-templates` (its Makefile and
`opt/bin/build.lua`); unlike that project no executable `.ex` is built.

## 9. Interpreter compatibility

Supported: Lua 5.1, 5.2, 5.3, 5.4, 5.5 and LuaJIT 2.1. Development
environment (macOS):

| interpreter | luaposix | luv |
|---|---|---|
| `~/Developer/cli-util-mods/opt/bin/lua` (lua-regolith, Lua 5.5.1) | yes | yes |
| `~/Developer/cli-util-mods/opt/bin/lua-static` (Lua 5.5.1, modules preloaded) | yes | yes |
| `/opt/homebrew/bin/lua` (Lua 5.5.1) | no | yes |
| `/opt/homebrew/bin/luajit` (2.1, `jit.os == "OSX"`) | no | yes |

No Lua 5.1 to 5.4 interpreter is installed; LuaJIT covers 5.1 semantics.
Measured differences that the code must handle:

| feature | Lua 5.2 to 5.5 | Lua 5.1 and Homebrew LuaJIT |
|---|---|---|
| `io.popen(...):close()` | `true\|nil, "exit"\|"signal", code` | `true` only, even after `exit 3` |
| `os.execute(cmd)` | `true\|nil, "exit", code` | raw status: `0`, or `768` for exit 3 |
| `__gc` on a table | fires | never fires; use `newproxy(true)` |
| `table.unpack` | yes | `unpack` only |
| `goto` | yes | no (LuaJIT has it; 5.1 does not) |
| `__bor` metamethod | 5.3 and newer | no |

Rules: `local unpack = table.unpack or unpack`; no `goto`; test success of
`os.execute` with `r == true or r == 0`; Lua 5.5 makes `for` loop variables
read-only, so never assign to one; `os.tmpname` creates the file on 5.4 and
newer only (the design does not rely on it); `#!` lines and `arg` are
absent when the library is required, so never read `arg` in a module.

## 10. Defects in the reference code

Consolidated from the earlier review and from measurements in this
environment; each is fixed by the design above.

| # | file | defect |
|---|---|---|
| 1 | init.lua | hard `require("posix")` at the top: the gating requirement fails before anything else runs |
| 2 | init.lua | `sh.__verbose` and `sh.__raise_errors` are silently ignored (`config` replaced them); `simple-modules` and the tests set them |
| 3 | init.lua | `error(stderr)` raises an empty message when stderr is merged or empty |
| 4 | init.lua | `pushd` runs `pwd` as a process; `sys.getcwd` is available |
| 5 | init.lua | version string format changed; the test compares the whole string |
| 6 | pipe_posix.lua | no `name` field, so `backend_name()` is nil for posix (measured) |
| 7 | pipe_posix.lua | whole input written before reading: deadlock above the pipe buffer size |
| 8 | pipe_posix.lua | SIGPIPE kills the process when the child exits before reading stdin (measured: exit 141) |
| 9 | pipe_posix.lua | `assert` after `execp` in the forked child |
| 10 | pipe_posix.lua | verbose output truncated and newline-mangled; stderr printed on stdout (measured) |
| 11 | pipe_posix.lua | `table.unpack` is nil on Lua 5.1 |
| 12 | pipe_luv.lua | `error()` on spawn failure instead of the 127 convention |
| 13 | pipe_popen.lua | temp files: symlink and permission race (`io.open` then `chmod`), one `chmod` process per file |
| 14 | pipe_popen.lua | custom-dir names from `os.clock()` and unseeded `math.random` can collide across processes |
| 15 | pipe_popen.lua | `cleanup_all` comment promises automatic cleanup that is not implemented |
| 16 | pipe_popen.lua | `basic` exposes stdin data in process listings; not documented |
| 17 | args.lua | `false` emits the flag; `""` raises a confusing error; order nondeterministic |
| 18 | pipe.lua | no platform table, no capabilities; `set_backend` writes options into the backend module table |

## 11. Decisions and assumptions to confirm

- Android prefers luv over luaposix (section 6.4).
- Table flags are emitted in sorted key order (section 7).
- The error message with `raise_errors` keeps the raw stderr text when
  there is one (section 3.6), so existing callers see the same text.
- Windows support in the popen backend is best effort and untested.
- Pipeline stages run sequentially; `Pipeline:run()` is sugar over the
  existing chaining, not a concurrent pipe.
