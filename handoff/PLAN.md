# LuaSH 2.0 implementation plan

Companion to `DESIGN.md`; a reference like `§6.3` points to a section
there. The work is cut into packages WP0 to WP8 that own disjoint files, so
WP1 to WP6 can run as parallel sessions. Each package is written as a brief
for one implementer who has read `DESIGN.md` and this section 1, and
nothing else from the discussion that produced them.

## 1. Rules for every package

### 1.1 Branches and ownership

- Start from `master`. Work on a branch named `wp<N>-<slug>` (for example
  `wp2-posix`). Commit on it as you go; push nothing; merge nothing. WP8
  merges the branches.
- Edit only the files your package owns (listed in each brief). When you
  need another package's module, code against its interface in
  `DESIGN.md`; when you need it to run, use `tests/backend_fake.lua` (WP0)
  or point `LUA_PATH` at `handoff/reference/sh/` as a stand-in, and say in
  your commit message what you could not verify.
- Never edit `handoff/**`, `tests/gambiarra.lua`, or the root `sh.lua`
  (WP5 deletes it, nothing else touches it).
- Every `.lua` file under `sh/` is a module: `local M = {}` at the top,
  `return M` at the bottom, no globals, no `arg`, no shebang.

### 1.2 Environment

Development machine: macOS, no luarocks, no `timeout(1)`, no `/dev/shm`,
`shellcheck` installed. Interpreters:

```bash
REG=$HOME/Developer/cli-util-mods/opt/bin   # lua-regolith
$REG/lua          # Lua 5.5.1 with luaposix 36.3 and luv 1.52.1
$REG/lua-static   # Lua 5.5.1, same modules preloaded into the binary
$REG/luac         # `luac -p file.lua` is the parse check
lua               # /opt/homebrew/bin/lua, Lua 5.5.1, luv only, no luaposix
luajit            # /opt/homebrew/bin/luajit, LuaJIT 2.1, luv only
```

Run everything from the repository root with the package path set
explicitly (`;;` appends the interpreter's default path):

```bash
export LUA_PATH="./?/init.lua;./?.lua;./tests/?.lua;;"
```

`./?/init.lua` comes first so that `require("sh")` resolves to
`sh/init.lua` while the old root `sh.lua` still exists on your branch.
`./tests/?.lua` makes `require("backend_fake")` work.

To simulate a host without luaposix and luv on the regolith interpreter:

```bash
$REG/lua -e 'package.cpath = ""; package.preload.posix = nil; package.preload.luv = nil' tests/test.lua
```

Any `require("posix")` or `require("luv")` then fails, and the library
must fall back to the popen backend.

### 1.3 Tests

- Framework: `tests/gambiarra.lua`, used as in `tests/test.lua`:
  `test("name", function() ok(cond, "message") end)`, a reporter that
  counts failures, `os.exit(1)` when any failed.
- Every test file sets `package.path` from its own location with a copy
  of the `init()` function at the top of `tests/test.lua`, extended by
  `prepend_path(pth .. "/../?/init.lua")`, so that it also runs as
  `lua tests/test_x.lua` without `LUA_PATH`.
- A test file that cannot run on the current interpreter (backend missing,
  feature missing) prints one line `SKIP: <reason>` and exits with
  status 0. The matrix runner counts those separately.
- Tests use only programs that exist on macOS and Linux: `sh`, `cat`,
  `echo`, `printf`, `seq`, `wc`, `grep`, `head`, `sort`, `true`, `false`,
  `ls`, `pwd`, `uname`, `kill`. No network, no `sleep` longer than one
  second.
- Expected output of the current suite, for reference:
  `$REG/lua tests/test.lua` prints one `✔` line per check and exits 0.

### 1.4 Code style: `AGENTS.md` applied to this repository

`AGENTS.md` at the repository root is the style guide. It was written for
several languages and repositories; this is what applies here.

Applies to every Lua file:

- 4 spaces, about 80 columns, one action per line, local alignment of a
  small group of related assignments or table fields.
- Wrapped calls: function name and `(` together, arguments at +4 from the
  statement's indentation, several short arguments per line, `)` alone at
  the statement's indentation. A single table or call argument hugs the
  parentheses.
- Wrapped function definitions use the 12/8 layout: parameters at +12,
  `)` at +8, body at +4. It applies to `function M.f(` and
  `local function f(` alike. Most Lua signatures fit on one line; wrap
  only those that do not.
- A short guard such as `if not ok then return nil, err end` may stay on
  one line; a line with two actions is split.
- Apply the style to the code you write and change; do not reformat a
  file you only pass through.

```lua
local function run_with_files(
            tmpdir, argv, input, opts,
            on_stdout, on_stderr
        )
    local infile = tmppath(tmpdir, "in")
    -- ...
end

local result = backend.run(
    argv, input,
    { on_stdout = out_cb, on_stderr = err_cb, cwd = cwd }
)

setmetatable(M, {
    __call  = function(_, name, ...) return command(name, ...) end,
    __index = index_module,
})

local ok, posix = pcall(require, "posix")
```

Applies in a limited way:

- Bash refinements: only to `tests/run_all.sh` (a bash script:
  `set -euo pipefail`, `local` per line, arrays for optional arguments,
  shellcheck clean) and to the shell strings the popen backend and
  `sys.lua` build for `io.popen` and `os.execute`. Those strings are POSIX
  `sh`: no `[[ ]]`, no arrays, no `&>`, every argument single-quoted. The
  rule that a script starts with `set -eu` is for scripts, not for a
  one-command string.
- YAML: if WP6 adds `.github/workflows/test.yml`, it uses 2-space
  indentation as the YAML rule says.

Does not apply: the Rust and Nushell sections, the Containerfile, `RUN`,
`SHELL` and `/etc/profile.d` rules, and the section "Scope in this
repository", which names `vendor/**`, `slinky-*` symlinks, `generated/**`
and SchedMD headers that belong to another repository. For luash read that
section as:

> Never restyle `tests/gambiarra.lua` or `opt/bin/build/amalg.lua`: they
> are vendored third-party code, kept verbatim so their diff against
> upstream stays empty. `standalone/sh.lua` is generated by
> `make standalone`; regenerate it, never edit it. `handoff/reference/**`
> is frozen reference material. Apply the style to new and changed code
> without reformatting unrelated sections; convert a whole file only in a
> dedicated formatting commit.

(That paragraph is proposed as the replacement text for the section; the
repository owner decides whether to put it into `AGENTS.md`.)

Lua conventions that `AGENTS.md` does not cover: `local` for everything;
public functions get a `---` doc comment line (one sentence, then `@param`
and `@return` lines in Lua Language Server syntax, as `sh.lua` already
does for `command`); error messages start with the function or module
name (`"sh.popen: ..."`); strings use double quotes unless the string
contains one.

### 1.5 Compatibility checklist (§9)

Target: Lua 5.1, 5.2, 5.3, 5.4, 5.5 and LuaJIT 2.1. Before you commit, grep
your files for each of these:

- `table.unpack` -> `local unpack = table.unpack or unpack` at the top.
- `goto` -> not allowed.
- `os.execute(...)` result -> success is `r == true or r == 0`.
- `h:close()` on a popen handle -> may return only `true`; never rely on
  the status it returns without the feature test in §6.3.
- `__gc` on a table -> use `newproxy(true)` when `newproxy` exists.
- Bit operators `|`, `&`, `~`, `//` and integer division -> not allowed
  (syntax error on 5.1 to 5.2 and LuaJIT); `__bor` as a metamethod key is
  fine.
- Assignment to a `for` loop variable -> not allowed (Lua 5.5).
- `#!` line or `arg` in a module -> not allowed.
- `require("posix")` or `require("luv")` outside `pcall` -> not allowed
  anywhere, including `sys.lua` and the backends.
- `string.format("%d", x)` with a non-integer float `x` raises on 5.3 and
  newer; format counters with `%d` only when they are integers.

Parse check on both syntaxes: `$REG/luac -p file.lua` and
`luajit -bl file.lua > /dev/null`.

### 1.6 Definition of done

A package is done when all of these hold and the commit message says so:

1. Every owned test file passes on every interpreter of section 1.2, or
   prints `SKIP:` with a reason that section 1.3 allows.
2. Every owned Lua file passes both parse checks of section 1.5.
3. `grep -n 'require("posix")\|require("luv")' <owned files>` shows only
   lines that contain `pcall`.
4. The acceptance commands in the brief produce the stated result.
5. The style of section 1.4 is applied; `shellcheck` is clean for shell
   code.

## 2. Dependency graph and schedule

```
wave 1 (parallel):   WP0 contract test      WP1 command.lua      WP6 build tooling
                         |                      |
wave 2 (parallel):   WP2 posix  WP3 luv  WP4 popen           WP5 init/pipe/sys
                         \         |        /                     |
wave 3:                   WP8 stage 1: merge WP0-WP6 into master -+
                                        |
wave 4:                              WP7 tests and docs
                                        |
wave 5:                   WP8 stage 2: standalone, matrix, release
```

- WP0 is small and the coordinator does it first; WP2, WP3 and WP4 need
  its contract test from the start.
- WP5 needs the `sh/command.lua` interface. It can start as soon as WP1's
  `M.parse` and `M.Command` exist on the `wp1-command` branch (copy that
  one file into your checkout while WP1 finishes; do not commit it).
- WP6 needs only the module names in §2.
- WP7 starts from `master` after stage 1, so it runs against the real
  modules.

Rough sizes: WP0 1 h, WP1 3 h, WP2 4 h, WP3 3 h, WP4 5 h, WP5 5 h,
WP6 3 h, WP7 5 h, WP8 3 h.

## 3. Work packages

### WP0: backend contract test and fake backend (coordinator)

Owns `tests/backend_fake.lua`, `tests/test_backend.lua`.

`tests/backend_fake.lua` is the smallest implementation of §4 and exists
so that WP5 and the contract test itself can be developed before the real
backends exist:

- `name = "fake"`; `available()` returns `pcall(io.popen, "exit 0")`
  truthiness; `configure(opts)` does nothing.
- `capabilities()`: `stdin = true`, `separate_stderr = false`,
  `streaming = false`, `signals = false`, `exitcode` from the feature test
  of §6.3 (`io.popen("exit 7"):close()` reports 7 or not).
- `run(argv, input, opts)`: check `argv` (non-empty array of strings,
  `error()` otherwise); write `input` to a file from `os.tmpname()`
  (opened with `io.open(path, "wb")`); build
  `'<argv[1]>' '<argv[2]>' ... < '<file>' 2>&1`, with `'` in an element
  written as `'\''`, prefixed by `cd '<cwd>' && ` when `opts.cwd` is set;
  `io.popen(cmd, "r")`, `read("*a")`, `close()`; remove the file; call
  `opts.on_stdout(out)` once when `out ~= ""`; return
  `{ exitcode = code or 0, signal = 0, stdout = out, stderr = "",
  cause = "exited" }`.

`tests/test_backend.lua <name> [strategy]` loads `sh.backend.<name>`, or
`backend_fake` when `<name>` is `fake`, calls `configure({strategy =
strategy})` when a strategy is given, prints `SKIP:` and exits 0 when
`available()` is false, and otherwise checks, with `caps =
B.capabilities()`:

1. `B.name == name`; `caps.name == name`; the five boolean fields exist.
2. `run({"echo", "hello"}, "")`: `stdout == "hello\n"`, `stderr == ""`,
   `cause == "exited"`, `signal == 0`, and `exitcode == 0` when
   `caps.exitcode`.
3. When `caps.stdin`: `run({"cat"}, "abc\n")` gives `stdout == "abc\n"`;
   `run({"cat"}, big)` with `big = string.rep("0123456789abcdef\n",
   20000)` (340 KB) gives `stdout == big` (the pipe-buffer deadlock test;
   it must return, not hang).
4. `run({"sh", "-c", "echo out; echo err >&2"}, "")`: when
   `caps.separate_stderr`, `stdout == "out\n"` and `stderr == "err\n"`;
   otherwise `stdout` contains both `out` and `err` and `stderr == ""`.
5. When `caps.exitcode`: `run({"sh", "-c", "exit 3"}, "")` has
   `exitcode == 3`.
6. `run({"luash-no-such-program-xyz"}, "")`: `exitcode == 127`,
   `stderr ~= ""`, `stdout == ""`.
7. Streaming callbacks: run `{"sh", "-c", "printf 'a\\rb\\r'; printf 'x\\n'
   >&2"}` and `{"seq", "1", "20000"}` with `on_stdout` and `on_stderr`
   appending to buffers; the concatenated buffers equal the returned
   `stdout` and `stderr` byte for byte (for a merged backend the stderr
   buffer is empty). When `caps.streaming`, the `seq` run delivered more
   than one stdout chunk.
8. When `caps.signals`: `run({"sh", "-c", "kill -9 $$"}, "")` has
   `cause == "killed"` and `signal == 9`; otherwise `exitcode == 137`
   when `caps.exitcode`.
9. Argument fidelity: `run({"printf", "%s\n", "a b", "it's", "", "--",
   "$HOME", "*", "a;b", "`x`"}, "")` returns
   `"a b\nit's\n\n--\n$HOME\n*\na;b\n`x`\n"`.
10. `run({"pwd"}, "", {cwd = "/"})` returns `"/\n"`.
11. `pcall(B.run, {}, "")` and `pcall(B.run, {"echo", 1}, "")` both return
    false.

Acceptance: `lua tests/test_backend.lua fake` passes on all four
interpreters; `lua tests/test_backend.lua posix` prints `SKIP:` on the
Homebrew interpreters (module not found) and fails with a clear message on
`$REG/lua` (backend not written yet).

### WP1: `sh/command.lua`

Owns `sh/command.lua`, `tests/test_command.lua`. Replaces
`handoff/reference/sh/args.lua`, whose `flatten` is the starting point.
Read §3.4, §3.5 (Result shape), §7.

Exports:

- `M.parse(...)` applies §7 to its arguments and returns
  `{ args = {...}, input = "", sources = {...}, fields = {...} }`:
  `args` the positional strings and flags in order; `input` the
  concatenated `__input` strings; `sources` the `__pipeline` values of
  Result arguments in order (skipping nil); `fields` the pass-through
  `__stdout`, `__stderr` (concatenated like today's `flatten`),
  `__exitcode` and `__signal` (the last seen) for builtins. A Result is
  recognised by having a string field `__stdout`.
- `M.quote(s)`: the rendering rule of §3.4 for one argument.
- `M.Command(name, ...)`, `M.Pipeline(...)` with the methods of §3.4;
  `__tostring` on both; `__bor` on both; `__name` set; `__index` to the
  method tables. `Command:argv()` and `Pipeline:commands()` return fresh
  tables. `Command:input(x)` accepts a string or a Result (then it takes
  `__input` and records the Result's `__pipeline` as a source).
- `M.set_runner(fn)`; `Command:run()` calls `fn(self)` and returns its
  value; `Pipeline:run()` runs the stages in order, passing the previous
  stage's Result as input to the next one, and returns the last Result.
- `M.render(pipeline)`: the string behind `__tostring`, with the grouped
  form `{ a; b; } | c` when a stage has more than one source.
- `M.is_command(x)`, `M.is_pipeline(x)`: metatable `__name` checks.

`tests/test_command.lua` (no process is started; `set_runner` with a stub
that records calls):

- `parse("a", 1, {"-b", {"c"}})` gives `{"a", "1", "-b", "c"}`.
- `parse({format = "%a", v = true, q = false, n = 3, e = ""})` gives
  `{"--format=%a", "-n=3", "-v", "--e="}` in exactly that (sorted) order;
  `q` is absent; a function value raises an error naming the key.
- `parse({__input = "x"}, {__input = "y"})` has `input == "xy"`; a fake
  Result `{__stdout = "o", __stderr = "e", __exitcode = 2, __signal = 0,
  __input = "o", __pipeline = p}` contributes `input == "o"`, `sources ==
  {p}`, `fields.__exitcode == 2`.
- `tostring(Command("ls", "-l", {color = "auto"}):arg("a b", ""))` is
  `ls -l --color=auto 'a b' ''`; `quote("it's")` is `'it'\''s'`;
  `quote("a/b.c_d=e")` is bare.
- `flag("l")` gives `-l`, `flag("color", "auto")` gives `--color=auto`,
  `flag("x", false)` adds nothing, calls chain and return the command.
- `tostring(Command("seq", 1, 10):pipe(Command("wc", "-l")))` is
  `seq 1 10 | wc -l`; `Pipeline(a, b):pipe(c):commands()` has three
  entries and `#` of the original stays 2 after `commands()` is modified.
- A stage with two sources renders as `{ seq 1 10; seq 20 25; } | wc -l`.
- `__bor`: set `_G.luash_test_a = ca` and `_G.luash_test_b = cb`, then
  `(loadstring or load)("return luash_test_a | luash_test_b")`. On Lua 5.3
  and newer the chunk compiles and returns a Pipeline whose rendering is
  `a | b`; on 5.1, 5.2 and LuaJIT the compile fails (nil and a syntax
  error) and the test records a pass with a note.
- `Command("x"):run()` before `set_runner` raises a message containing
  `no runner`; after `set_runner`, `run()` returns what the stub returns
  and the stub received the Command; `Pipeline:run()` called the stub once
  per stage and passed the previous Result as the next stage's input.

Acceptance: `lua tests/test_command.lua` passes on all four interpreters
(`__bor` check passes on 5.5 and notes on LuaJIT).

### WP2: `sh/backend/posix.lua`

Owns `sh/backend/posix.lua`. Read §4, §5, §6.1, `handoff/reference/sh/
pipe_posix.lua` and the `popen3` function in the root `sh.lua` (the
fork/pipe/dup2 sequence is right; keep it).

luaposix 36 facts you need (all verified on the regolith interpreter):

- `local ok, posix = pcall(require, "posix")` at the top; `available()`
  returns `ok` and, when false, the error text.
- `posix.pipe()` returns `r, w`; `posix.fork()`; `posix.dup2(old, new)`;
  `posix.close(fd)`; `posix.chdir(dir)` returns `0` or `nil, err`.
- `posix.execp(path, argt)`: `argt` is the argument table without the
  program name (`argt[0]` may hold argv[0]; omit it). It returns only on
  failure, as `nil, err`.
- `posix.write(fd, s)` returns the number of bytes written (may be less
  than `#s` on a non-blocking fd) or `nil, msg, errno`; compare `errno`
  with `posix.EPIPE` and `posix.EAGAIN`.
- `posix.fcntl(w, posix.F_SETFL, posix.O_NONBLOCK)` on the fresh write
  end (its flags are 0, so no `F_GETFL` round trip and no bit operators
  are needed).
- `posix.poll(fds, timeout)` with
  `fds = { [fd] = { events = { IN = true } }, [w] = { events = { OUT = true } } }`;
  after it returns, `fds[fd].revents` has booleans `IN`, `OUT`, `HUP`,
  `ERR`, `NVAL`. Use `timeout = -1`.
- `posix.read(fd, 4096)` returns `""` or `nil` at EOF.
- `posix.wait(pid)` returns `pid, "exited" | "killed" | "stopped", code`.
- `posix.signal(posix.SIGPIPE, posix.SIG_IGN)` returns the previous
  handler (`"SIG_DFL"`, `"SIG_IGN"` or a function); restore it with the
  same call.
- `posix._exit(code)` in the child.

Structure: `B.run` = `spawn` (fork, child setup, exec or `_exit(127)`
with a message on fd 2) + `pump` (the poll loop of §6.1, writing `input`
in slices of 65536 bytes, reading both outputs into chunk arrays, calling
`opts.on_stdout` / `opts.on_stderr` per chunk) + `wait` (map
`exited`/`killed`/`stopped` to `exitcode`, `signal`, `cause`). Return
`stdout = table.concat(chunks)`. No `print`, no `io.write` anywhere in the
module.

Acceptance: `$REG/lua tests/test_backend.lua posix` and
`$REG/lua-static tests/test_backend.lua posix` pass every check including
the 340 KB `cat` and the `kill -9`; `lua tests/test_backend.lua posix`
prints `SKIP:`. Also run this by hand and confirm the process exits 0, not
141:

```bash
$REG/lua -e 'local B = require("sh.backend.posix"); local r = B.run({"head", "-c", "1"}, string.rep("x", 1000000), {}); print(r.exitcode, #r.stdout)'
```

### WP3: `sh/backend/luv.lua`

Owns `sh/backend/luv.lua`. Read §4, §5, §6.2 and
`handoff/reference/sh/pipe_luv.lua`, which is close to the final shape.

luv facts: `local ok, uv = pcall(require, "luv")`; `uv.new_pipe(false)`;
`uv.spawn(path, { args = rest, stdio = { stdin, stdout, stderr }, cwd =
opts.cwd }, function(code, signal) ... end)` returns `handle, pid` or
`nil, err, name` (`args` excludes the program name); `pipe:read_start(
function(err, chunk) ... end)` where `chunk == nil` means EOF;
`pipe:write(data, function(err) ... end)`; `pipe:shutdown(cb)`;
`pipe:close()`; `handle:close()`; `uv.run("once")` runs one loop
iteration, `uv.run("nowait")` drains callbacks without blocking.

Changes from the reference: return the `cause = "failed"` result on spawn
failure instead of `error()`; close every pipe and the process handle in
all paths; count three completion events (exit, stdout EOF, stderr EOF)
before leaving the loop; a write error (child closed stdin) closes the
stdin pipe and is not an error; `signal > 0` in `on_exit` gives `cause =
"killed"`; empty input closes stdin right after spawn; honour `opts.cwd`.
Document in the module comment that `run` must not be called from inside
a libuv callback.

Acceptance: `lua tests/test_backend.lua luv`, `luajit
tests/test_backend.lua luv`, `$REG/lua tests/test_backend.lua luv` and
`$REG/lua-static tests/test_backend.lua luv` all pass every check.

### WP4: `sh/backend/popen.lua`

Owns `sh/backend/popen.lua`, `tests/test_popen.lua`. Read §4, §5, §6.3,
§9 and `handoff/reference/sh/pipe_popen.lua` (keep its strategy names
and its `shell_escape`; replace its temp-file handling).

Structure:

- `render(argv, files, cwd, mode)` builds the shell string; `files` holds
  the absolute paths `input`, `stderr`, `status` or is nil for the merged
  strategies; `mode` is `"sh"` or `"cmd"` (Windows, §6.3, one function,
  marked best effort). Expose it as `B._render` for the tests.
- `tmpdir()` creates the private directory lazily (§6.3: `mkdir -m 700`,
  random suffix, retry on failure, `os.execute` success test `r == true or
  r == 0`), remembers its path, and registers the `__gc` sentinel
  (`newproxy(true)` when `newproxy` exists, a table otherwise).
- `strategies = { shmem = ..., standard = ..., basic = ..., minimal = ... }`,
  each with `available()` and `run(argv, input, opts)`; `shmem` and
  `standard` share one implementation parameterised by the temp root.
- `B.configure({strategy = ..., tmpdir = ...})`; `B.capabilities()`
  reflects the resolved strategy; `B.available_strategies()`;
  `B.cleanup_all()`.
- Exit status: file strategies read it from the status file; merged
  strategies use `h:close()` only when the load-time feature test says it
  reports a status (§6.3).
- Reading: `h:read(4096)` loop, `on_stdout` per chunk; stderr file read
  after close and passed to `on_stderr` once.
- Every temp file is removed in a `pcall`-protected cleanup that runs
  whether the command succeeded or not.

`tests/test_popen.lua`:

- For each strategy in `B.available_strategies()`, run the contract
  checks by loading `tests/test_backend.lua` logic (factor its checks into
  a function it exports when called with no arguments, or simply spawn
  `lua tests/test_backend.lua popen <strategy>` through `io.popen` and
  check its exit status).
- `B._render({"a b", "it's"}, {input = "/t/in-1", stderr = "/t/err-1",
  status = "/t/st-1"}, "/w", "sh")` equals
  `cd '/w' && 'a b' 'it'\''s' < '/t/in-1' 2> '/t/err-1'; echo "$?" > '/t/st-1'`
  and the merged forms end in `2>&1` with `</dev/null` for minimal; when
  `shellcheck` is on `PATH`, write each rendered string to a file and run
  `shellcheck -s sh` on it (skip with a note otherwise).
- After a `standard` run the private directory exists, `ls -ld` shows
  `drwx------`, and it contains no `in-*`, `err-*` or `st-*` files;
  `B.cleanup_all()` removes it; the next run recreates it.
- Two runs with the same input in a row do not share files (counter
  advances); the status file gives `exitcode == 3` for `sh -c 'exit 3'`
  on LuaJIT, where `close()` reports nothing.
- `shmem` is reported unavailable on macOS and the test says so.

Acceptance: `tests/test_popen.lua` and `tests/test_backend.lua popen
<strategy>` pass for `standard`, `basic` and `minimal` on all four
interpreters (`minimal` skips the stdin checks through its capability).

### WP5: `sh/init.lua`, `sh/pipe.lua`, `sh/sys.lua`, `sh/stack.lua`

Owns those four files; deletes the root `sh.lua` and the
`experiments/sh.lua` symlink (`git rm`). Read §3 (all of it), §6.4, §6.5,
§7, the root `sh.lua` (the behaviour to keep: builtins, `install()`,
Result metatable, `tostring`/`concat`) and `handoff/reference/sh/init.lua`,
`pipe.lua`, `stack.lua`.

`sh/stack.lua`: the reference file, restyled.

`sh/sys.lua` (§6.5): `platform()`, `chdir(dir)`, `getcwd()`,
`emulated_cwd()` (nil when a real `chdir` is available), each `require`
behind a cached `pcall`.

`sh/pipe.lua` (§6.4): the `ORDER` table, lazy `pcall(require,
"sh.backend." .. name)`, `resolve()` honouring `config.backend`,
`LUASH_BACKEND` and `LUASH_POPEN_STRATEGY`, `set_backend(name_or_table,
opts)`, `backend_name()`, `available_backends()`, `capabilities()`,
`run(argv, input, pipeline)`: builds the callbacks from `config`
(`sink` or `io.stdout`/`io.stderr` with `flush()` after each write),
writes the trace line, passes `sys.emulated_cwd()` as `opts.cwd`, raises
on non-empty input without the `stdin` capability. It takes the config
table at `set_config(tbl)` from `init.lua` so that it never requires
`sh.init`.

`sh/init.lua`: `M.version`; `M.config` (§3.2); module metatable with
`__call`, `__index` (aliases `__verbose`/`__raise_errors`, then builtins
from `M.FUNCTIONS` for names in `M.__index_ignore_function`, then
`command(name)`) and `__newindex` (aliases, else `rawset`);
`make_result(fields, pipeline)` with the metatable of §3.5; `command(name,
preargs...)` returning the closure that calls `command_mod.parse`, builds
the `Command` (preargs first), appends it to the Pipeline of the sources
(a new Pipeline when there are none; a grouped stage when there are
several), calls `pipe.run`, applies §3.6, returns the Result; the runner
installed with `command_mod.set_runner` is the same function, so
`Command:run()` and `sh.name(...)` share one path; builtins `cd`,
`pushd`, `popd`, `stdout`, `stderr`, `print` with today's messages and
pass-through, `pushd` using `sys.getcwd()`; `install()` unchanged in
behaviour; exports listed in §3.3 and `M.Command`, `M.Pipeline`.

Acceptance, with `LUA_PATH` as in section 1.2 and `sh/command.lua` from
the `wp1-command` branch copied in:

```bash
# structure and behaviour with the fake backend, all four interpreters
lua -e 'local sh = require("sh"); sh.set_backend(require("backend_fake"))' tests/test.lua
```

passes every test except "Check Version" (WP7 updates the string to
2.0.0). Then, by hand on `$REG/lua`:

- `require("sh").backend_name()` prints `posix` when `sh/backend/posix.lua`
  from `wp2-posix` is present, `popen` under the no-C-modules command of
  section 1.2 when `sh/backend/popen.lua` from `wp4-popen` is present,
  and a clear error naming the missing module when neither exists (never
  a nil index error).
- `sh.__verbose = true; sh.seq(1, 3)` streams `1\n2\n3\n` to stdout
  unchanged; with `sh.config.sink = function(s, c) io.write("[", s, "]",
  c) end` it prints `[stdout]1\n2\n3\n`.
- `sh.config.trace = true; sh.seq(1, 3):wc("-l")` prints `+ seq 1 3` then
  `+ seq 1 3 | wc -l` on stderr.
- `sh.config.raise_errors = true; sh.ls("/missing")` raises the `ls`
  message; `sh.sh("-c", "exit 3")` raises `sh -c 'exit 3': exit status 3`.
- `tostring(sh.seq(1, 10):wc("-l").__pipeline)` is `seq 1 10 | wc -l`.
- `sh.cd("/"); print(sh.pwd())` prints `/` on every backend; the same with
  `package.cpath = ""` exercises the emulation (only once `wp4-popen` is
  present).

### WP6: build tooling, rockspec, CI, test matrix

Owns `opt/bin/build.lua`, `opt/bin/build/amalg.lua`, `Makefile`,
`rockspec/sh-scm-3.rockspec` (replaces `sh-scm-2.rockspec`),
`rockspec/sh-2.0-1.rockspec`, `tests/run_all.sh`,
`.github/workflows/test.yml`, `.travis.yml` (delete), `.luarc.json`.
Read §2, §8, §9 and `../simple-templates/opt/bin/build.lua`,
`../simple-templates/Makefile`.

- `opt/bin/build/amalg.lua`: copy verbatim from
  `../simple-templates/opt/bin/build/amalg.lua`. Never restyle it.
- `opt/bin/build.lua`: a Lua script with a `#!/usr/bin/env lua` line and
  no dependencies beyond the standard library. It finds the repository
  root from `arg[0]` (`debug.getinfo(1).source` as a fallback), sets
  `package.path = root .. "/?.lua;" .. root .. "/?/init.lua"`, loads
  `opt/bin/build/amalg.lua` with `loadfile` in an environment that
  inherits `_G` (as the simple-templates script does), and calls it as
  `amalg("-o", root .. "/standalone/sh.lua", "-s", root .. "/sh/init.lua",
  "sh.command", "sh.pipe", "sh.sys", "sh.stack", "sh.backend.posix",
  "sh.backend.luv", "sh.backend.popen")`. The module list is derived by
  scanning `sh/` (subdirectory `backend` gives `sh.backend.<file>`) so a
  new module cannot be forgotten; `init.lua` is excluded from the list
  because it is the main script. Run `amalg` from the repository root
  (`-s` is read relative to the current directory; use absolute paths to
  be safe).
- `Makefile`: targets `standalone` (default, builds
  `standalone/sh.lua`), `test` (runs `tests/run_all.sh`), `clean`. No
  `.ex` executable, no `awk` shebang step: the output is a library.
- Rockspecs: `type = "builtin"` with `modules` mapping `sh` to
  `sh/init.lua` and each `sh.*` module to its file; `install.bin` keeps
  `sh.autogen`; dependencies `"lua >= 5.1"` only, with a comment that
  luaposix and luv are optional and detected at run time. Check the file
  loads: `lua rockspec/sh-2.0-1.rockspec`.
- `tests/run_all.sh`: bash, `set -euo pipefail`, shellcheck clean. For
  each interpreter found (the four of section 1.2; skip missing ones with
  a note), for each `LUASH_BACKEND` in `posix luv popen`, run
  `tests/test.lua`; for `popen` also each `LUASH_POPEN_STRATEGY` in
  `standard basic minimal`; then `tests/test_command.lua`,
  `tests/test_backend.lua <backend>` and `tests/test_popen.lua`; then
  `tests/test.lua` with `LUASH_STANDALONE=1` against `standalone/sh.lua`
  for `posix` and `popen`; then the no-C-modules command of section 1.2
  against both layouts. Count pass, fail and skip per line; print a
  summary table; exit 1 on any fail. Runs that print `SKIP:` count as
  skipped, not failed.
- `.github/workflows/test.yml` (optional but recommended, 2-space YAML):
  matrix over `lua 5.1, 5.2, 5.3, 5.4, luajit` with
  `leafo/gh-actions-lua` and `leafo/gh-actions-luarocks`, installing
  `luaposix` and `luv` through luarocks, running `tests/run_all.sh` with
  the interpreter list overridden by an environment variable
  (`LUASH_INTERPRETERS="lua"`). Delete `.travis.yml`.
- `.luarc.json`: add `"sh/?.lua"`-style workspace settings only if the
  Lua Language Server needs them; otherwise leave it.

Until `sh/` exists, test `build.lua` in a scratch copy of the repository
where `sh/` is populated with stubs: `init.lua` requiring the seven
modules and returning a table, each module returning `{}`. The built file
must `luac -p` clean, `dofile` to a table, and show every `require(
"posix")`/`require("luv")` line only inside `pcall` (there are none in
the stubs; the real check is at WP8).

Acceptance: `make standalone` in the scratch copy produces
`standalone/sh.lua`; `lua -e 'package.path = "./standalone/?.lua"; print(
require("sh"))` prints `table: ...`; `tests/run_all.sh` runs against the
current repository with the old `tests/test.lua` and reports the matrix
(most cells SKIP or FAIL at this stage; the runner itself must not
crash); `shellcheck tests/run_all.sh` is clean.

### WP7: test suite and documentation (after stage 1)

Owns `tests/test.lua`, `README.md`, `example.lua`. Starts from `master`
after WP8 stage 1 so that every module is real.

`tests/test.lua`:

- `init()` also prepends `pth .. "/../?/init.lua"`, and when
  `LUASH_STANDALONE` is set prepends `pth .. "/../standalone/?.lua"`
  last (so it wins) and skips `../?/init.lua`.
- After `require("sh")`: when `LUASH_BACKEND` names a backend that is not
  in `sh.available_backends()`, print `SKIP: backend <name> unavailable`
  and `os.exit(0)`. Print `sh.backend_name()` and the capabilities table
  once at the top.
- "Check Version" compares with `... LuaSH 2.0.0`.
- Keep every existing test. Tests that need stdin or separate stderr
  check `sh.capabilities()` and record a skip note instead of failing
  under `minimal`/`basic`.
- New tests: `sh.Command`/`sh.Pipeline` rendering through the public
  module; `__pipeline` on a chained Result; table flags sorted and `false`
  omitted (`sh.printf("%s\n", {b = false, a = true})` prints `-a`);
  verbose byte exactness through `sh.config.sink` for `seq 1 1500` and
  for `sh -c "printf 'a\rb\r'; printf 'x\n' >&2"` (the sink receives
  exactly the stdout and stderr bytes, on the right stream when
  `separate_stderr`); trace line format; missing command gives
  `__exitcode == 127` and non-empty `__stderr` with `raise_errors`
  off, and raises with it on; 340 KB through `cat`; `head -c 1` on 1 MB
  input returns (SIGPIPE); error message formats of §3.6; `sh.cd`,
  `sh.pushd`, `sh.popd` round trip with `sh.pwd()`; `sh.__verbose` alias
  reads back `sh.config.verbose`.

`README.md`: rewrite the installation section (luarocks from the
rockspec, or copy `standalone/sh.lua`; luaposix and luv optional), add
sections for backends and `sh.config`, `sh.Command`/`sh.Pipeline`, verbose
and trace, errors (the 127 convention replaces the traceback example),
`cd` emulation on the popen backend, and "Upgrading from 1.x" (what
changed: flags sorted, `false` omitted, `sh.PIPES` gone, `sh.__verbose`
and `sh.__raise_errors` still work, standalone file). Keep the existing
examples where they still hold. `example.lua`: add a Command/Pipeline
example.

Acceptance: `tests/run_all.sh` is green (every cell pass or skip) on the
development machine; `README.md` examples were each run once.

### WP8: integration (coordinator)

Stage 1, after WP0 to WP6: merge `wp0`, `wp1`, `wp2`, `wp3`, `wp4`, `wp5`,
`wp6` into `master` (disjoint files; resolve nothing by hand except
`tests/` additions), run `tests/test_backend.lua` for every backend on
every interpreter, run `tests/test.lua` per backend with the old version
string expected to fail, build `standalone/sh.lua` with `make standalone`,
run the gating grep of §8 on it, run the no-C-modules command against the
standalone file. Fix integration mismatches in small commits on `master`
(or send them back to the package's session). Then start WP7.

Stage 2, after WP7: `make standalone` again, commit the generated file,
`tests/run_all.sh` green, smoke-test `simple-modules`: in a scratch copy
of `../simple-modules`, replace `opt/lib/sh.lua` with `standalone/sh.lua`
and run `opt/bin/module.lua` on one example with `sh.__verbose = true`
in effect; `curl`-style progress output must render on one updating line.
Update `rockspec` version, tag, and remove `handoff/` or move it to
`docs/design/` as the owner prefers.

## 4. Risks and open points

- Windows paths in the popen backend and `sys.lua` are untested; they are
  isolated in one function each so a Windows user can fix them.
- Android ordering (luv before posix) is an assumption, one table line.
- The posix poll loop is new code on a path that today works for small
  inputs; the 340 KB and SIGPIPE checks in the contract test are the
  guard.
- `luajit` without `LUAJIT_ENABLE_LUA52COMPAT` cannot report exit codes
  for popen merged strategies; the capability table says so and the
  tests branch on it.
- `simple-modules` is the one known downstream user; its usage list in
  §1 of `DESIGN.md` is what must keep working.
