# Testing and your own backend

## The contract is the seam

A backend is a table with a `name` and six functions
([section 4](../DESIGN.md#4-backend-contract)): `available`,
`capabilities`, `configure`, `run`, `chdir` and `getcwd`. The registry
checks exactly that list, [`CONTRACT`][CONTRACT], and `sh.set_backend`
accepts any table that passes it. Because a backend never sees Commands or
Results, it can be tested alone.

[`tests/test_backend.lua`][test_backend] is that test.
`lua tests/test_backend.lua posix` (or `luv`, `popen <strategy>`, `fake`)
runs [`run_contract`][run_contract] against the backend: the capability
table has every key; `echo` returns its stdout and exit 0; stderr is
separate or merged as `separate_stderr` says; a missing program gives 127
and a message; the `on_stdout` and `on_stderr` callbacks receive what the
result holds; a killed child reports its signal, or `128 + N` without
signal support; arguments with spaces, quotes, globs and backquotes arrive
verbatim; the `cwd` option and `chdir`/`getcwd` work; malformed calls
raise. It prints `SKIP: <reason>` and exits 0 where the backend cannot run,
which the matrix counts separately.

[`tests/backend_fake.lua`][backend_fake] is the smallest backend that
passes: `io.popen` with stdin from a temp file, stderr merged and an
emulated `cd`, in about 150 lines. It is the worked example of the
contract.

## Writing one

Start from the fake, or wrap the backend in use as
[`examples/09_custom_backend.lua`][example09] does: it takes
[`require("sh.backend").current()`][current], forwards `available`,
`configure`, `chdir` and `getcwd`, logs every `run`, and installs itself
with `sh.set_backend(table)`. The rules that matter:

- `run(argv, input, opts)` returns `{ exitcode, signal, stdout, stderr,
  cause }`, never raises for a child's failure, and calls `opts.on_stdout`
  and `opts.on_stderr` with each chunk when they are given.
- `capabilities()` tells the truth about `stdin`, `separate_stderr`,
  `streaming`, `exitcode` and `signals`
  ([section 5](../DESIGN.md#5-capabilities)); the run path and the tests
  branch on it.
- `configure(opts)` runs before `available()` at every selection, and a
  `configure` that raises makes the backend unavailable for that reason.

Then run `tests/test_backend.lua` on it, loading it through
`package.preload["sh.backend.<name>"]` as [`tests/test_install.lua`][test_install]
does for its probe backend.

## The matrix

[`tests/run_all.sh`][run_all] runs each test file against each interpreter,
backend and popen strategy, against the single-file build, and on a host
without luaposix or luv, which it emulates with `package.cpath = ""`. Each
run prints `PASS`, `SKIP`, `FAIL` or `MISS`, a table follows, and
`LUASH_LOG_DIR` keeps every run's output. `make test` rebuilds
`standalone/sh.lua` first. The test files: [`test.lua`][test] (the public
API), [`test_command.lua`][test_command] (flattening, rendering, Command and
Pipeline), [`test_popen.lua`][test_popen] (shell strings, strategies, the
private directory, child interpreters), [`test_install.lua`][test_install]
(library loads after `sh.install()`) and the contract test.

[CI][ci] runs the matrix on Lua 5.1 to 5.5 and LuaJIT 2.1, installing
luaposix and, where it builds, luv through luarocks; a cell whose module is
missing reports `SKIP` rather than failing the job. The examples run there
too, on the default backend. [Section 9](../DESIGN.md#9-interpreter-compatibility)
lists what differs between the interpreters and how the code copes.

## How to

### Run the tests

```bash
make test
```

runs the whole matrix after rebuilding `standalone/sh.lua`. Each test
file also runs on its own from the root, with the interpreter of your
choice; it finds `sh/` itself:

```bash
LUASH_BACKEND=luv lua tests/test.lua
```

```bash
lua tests/test_backend.lua popen basic
```

`LUASH_POPEN_STRATEGY=basic` picks the strategy for the other files. The
examples are tests too: `examples/run_all.sh luajit`.

### Choose the interpreters and keep the logs

```bash
LUASH_INTERPRETERS="lua5.4 luajit" LUASH_LOG_DIR=logs tests/run_all.sh
```

Each run's output lands in `logs/<column>-<label>.log`; without
`LUASH_LOG_DIR` the logs are removed when nothing failed. `LUASH_TIMEOUT`
is the limit per run in seconds, 120 by default, 0 for none.

### Test as on a host without luaposix and luv

```bash
lua -e 'package.cpath = ""' tests/test.lua
```

```bash
LUASH_STANDALONE=1 lua tests/test.lua
```

The second runs against the single file, after `make standalone`; the
matrix runs both, and the release workflow runs them together.

### Test a backend of your own

Give it its name, `name = "mine"` in the table and `sh.backend.mine` as
the module, and run the contract test on it. From a file anywhere,
`package.preload` supplies the module:

```bash
lua -e 'package.preload["sh.backend.mine"] = function() return dofile("mine.lua") end' tests/test_backend.lua mine
```

From a test file of your own, `require("test_backend")` returns
`run_contract(B, name, strategy)`, which runs the same checks with that
file's reporter.

### Test a script without running programs

A backend table can stand in for the real one: it records the argument
vectors and answers with canned output, so a test of a script checks
what the script would run.

```lua
local calls = {}
local mock  = {
    name         = "mock",
    available    = function() return true end,
    configure    = function() end,
    chdir        = function() return true end,
    getcwd       = function() return "/" end,
    capabilities = function()
        return {
            name = "mock", stdin = true, separate_stderr = true,
            streaming = false, exitcode = true, signals = false,
        }
    end,
    run = function(argv, input, opts)
        calls[#calls + 1] = table.concat(argv, " ")
        return {
            exitcode = 0, signal = 0, cause = "exited",
            stdout   = "ok\n", stderr = "",
        }
    end,
}

sh.set_backend(mock)
sh.git("push", "origin", "main")
assert(calls[1] == "git push origin main")
sh.set_backend("auto")                 -- the real backend again
```

`cd` goes through `chdir`, so the mock decides what `sh.cd` reports, and
a `run` that returns `exitcode = 1` with text in `stderr` exercises the
script's error handling.

[CONTRACT]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L41
[test_backend]: https://github.com/JBlaschke/luash/blob/main/tests/test_backend.lua
[run_contract]: https://github.com/JBlaschke/luash/blob/main/tests/test_backend.lua#L71
[backend_fake]: https://github.com/JBlaschke/luash/blob/main/tests/backend_fake.lua
[example09]: https://github.com/JBlaschke/luash/blob/main/examples/09_custom_backend.lua
[current]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L226
[test_install]: https://github.com/JBlaschke/luash/blob/main/tests/test_install.lua
[run_all]: https://github.com/JBlaschke/luash/blob/main/tests/run_all.sh
[test]: https://github.com/JBlaschke/luash/blob/main/tests/test.lua
[test_command]: https://github.com/JBlaschke/luash/blob/main/tests/test_command.lua
[test_popen]: https://github.com/JBlaschke/luash/blob/main/tests/test_popen.lua
[ci]: https://github.com/JBlaschke/luash/blob/main/.github/workflows/test.yml
