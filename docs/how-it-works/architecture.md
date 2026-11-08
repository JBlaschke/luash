# Architecture

LuaSH is the module directory `sh/`. Each file has one job, fixed by the
design document in [section 2](../DESIGN.md#2-module-layout); the public
API is [section 3](../DESIGN.md#3-public-api).

| Module | Job |
|---|---|
| [`sh/init.lua`][init] | the public API: Results, the builtins, `sh.config`, `sh.install()` and backend control |
| [`sh/command.lua`][command] | `Command` and `Pipeline`, argument flattening, quoting and rendering; starts no process |
| [`sh/pipe.lua`][pipe] | the run path: one command through the backend in use, with verbose and trace |
| [`sh/backend/init.lua`][registry] | the registry: selects one backend and routes `run`, `chdir` and `getcwd` to it |
| [`posix.lua`][posix], [`luv.lua`][luv], [`popen.lua`][popen] | the backends, each a complete implementation of the [contract](../DESIGN.md#4-backend-contract) |
| [`sh/sys.lua`][sys] | platform detection and `load_pcall`, the guard around library loads |
| [`sh/stack.lua`][stack] | the stack behind `pushd` and `popd` |

Dependencies point one way: `init` requires `command`, `pipe`, `backend`
and `sys`; `pipe` requires `backend`; `backend` requires `sys`; the
backends and `command` require nothing else of `sh`. A backend never sees
a Command or a Result, which is what lets [tests/test_backend.lua](testing.md)
check each one alone.

## What happens at `sh.ls("-l")`

1. The module table has no field `ls`. Its metatable's
   [`index_module`][index_module] returns [`command("ls")`][command_fn], a
   function that builds a fresh Command at each call.
2. That function calls [`Command("ls", "-l")`][Command]. The arguments are
   flattened ([section 7](../DESIGN.md#7-argument-flattening-shcommandlua),
   [commands as data](commands.md)) into an argument vector, the literal
   stdin, and the Results that were passed in.
3. [`execute`][execute] records the provenance, the Pipeline the Result will
   show, and calls [`pipe.run`][pipe_run] with the vector, the stdin data
   and that Pipeline.
4. `pipe.run` adds the verbose callbacks and the trace line and calls
   [`backend.run`][backend_run], which goes to the backend selected when
   `sh` loaded.
5. The backend starts the program, feeds its stdin, collects stdout and
   stderr, and returns `{ exitcode, signal, stdout, stderr, cause }` as
   [section 4](../DESIGN.md#4-backend-contract) specifies.
6. `execute` wraps that in a [Result][make_result]; with `raise_errors` on,
   a failure becomes the error message of
   [section 3.6](../DESIGN.md#36-errors).

A chained call such as `r:grep("x")` takes the same path. Indexing a Result
falls back to the module ([`result_index`][result_index]), so `grep` is the
command function, and the Result arrives as its first argument, where
flattening takes `__input` as the stdin and `__pipeline` as the source.

## Two more entry points

[`sh.install()`][install] gives `_G` an `__index` so that an undefined
global becomes `command(name)`. First it loads the platform's backends with
[`preload`][preload]: libraries such as luaposix detect features by reading
optional globals, which must still be nil while they load. For a backend
loaded later, [`sys.load_pcall`][load_pcall] keeps them nil during the load.

`sh.Command` and `sh.Pipeline` build the same objects without running
them. `run()` on either calls the runner that `init` installs with
[`set_runner`][set_runner], which is `execute` again. That is what keeps
`command.lua` free of process code.

The other pages follow this path. [Pipes](pipes.md) is step 5 in each
backend, and [streaming](streaming.md) follows one chunk of output from
the backend's pump to the verbose callbacks of step 4;
[backend resolution](backends.md) is how step 4 found its backend,
[results](results.md) is step 6, and [configuration](configuration.md)
covers `sh.config` and the bundled single file.

## How to

### Call a program

Index the module with the program's name, or call `sh.install()` once
and use the name as a global. Either call runs the program at once and
returns its Result:

```lua
local sh = require("sh")
print(sh.uname("-s"))           -- through the module

sh.install()
print(uname("-s"))              -- as a global, after install()
```

A library should keep to the first form: `sh.install()` changes `_G` for
the whole program, and a misspelled global then runs a program of that
name, so the error is `sh: lenght: No such file or directory` rather
than `attempt to call a nil value`.

### Name a program that is not an identifier

`sh("pkg-config")` and `sh.command("true")` return the command function
for a name with a `-` in it or a Lua keyword. Further arguments are
preset: `sh.command("git", "log", "--oneline")` is a `git log --oneline`
that takes more arguments at each call
([example 3](../examples.md#3-flags-partial-commands-and-tricky-names)).

### Keep a global out of `install()`

After `sh.install()` every undefined global is a command function, which
a library that reads an optional global to detect a feature would take
for the feature; the backends load before the hook goes in for that
reason. A global of your own that must stay nil goes on
`sh.__index_ignore_exact`, or its prefix on `sh.__index_ignore_prefix`,
which the hook consults at every lookup:

```lua
sh.install()
table.insert(sh.__index_ignore_exact, "optional_hook")
print(type(optional_hook))      -- nil, not a function
```

### Build a command without running it

`sh.Command` and `sh.Pipeline` do step 2 and stop; `run()` continues at
step 3. [Commands as data](commands.md#how-to) has the recipes.

### Find the code behind a behaviour

| You see | Look in |
|---|---|
| a wrong word or flag on the rendered command line | [`sh/command.lua`][command]: `walk_table`, `format_flag`, `quote`; [commands](commands.md) |
| a setting that has no effect | [`sh/init.lua`][init]: `apply_config`, `set_backend`; [configuration](configuration.md) |
| output in the wrong stream, merged, or arriving late | the backend in use, `sh.backend_name()`, under [`sh/backend/`][backends_dir]; [pipes](pipes.md), [streaming](streaming.md) |
| a `cd` that the programs follow but `io.open` does not | [`sh/backend/popen.lua`][popen]; [working directory](cwd.md) |
| an unexpected error message or exit status | [`sh/init.lua`][init]: `failure`, `execute`; [results](results.md) |

[init]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua
[command]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua
[pipe]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua
[registry]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua
[posix]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua
[luv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua
[popen]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua
[sys]: https://github.com/JBlaschke/luash/blob/main/sh/sys.lua
[stack]: https://github.com/JBlaschke/luash/blob/main/sh/stack.lua
[index_module]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L445
[command_fn]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L247
[Command]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L371
[execute]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L196
[pipe_run]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L63
[backend_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L249
[make_result]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L136
[result_index]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L123
[install]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L374
[preload]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L292
[load_pcall]: https://github.com/JBlaschke/luash/blob/main/sh/sys.lua#L26
[set_runner]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L341
[backends_dir]: https://github.com/JBlaschke/luash/tree/main/sh/backend
