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
backend, [backend resolution](backends.md) is how step 4 found its backend,
[results](results.md) is step 6, and [configuration](configuration.md)
covers `sh.config` and the bundled single file.

[init]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua
[command]: https://github.com/JBlaschke/luash/blob/master/sh/command.lua
[pipe]: https://github.com/JBlaschke/luash/blob/master/sh/pipe.lua
[registry]: https://github.com/JBlaschke/luash/blob/master/sh/backend/init.lua
[posix]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua
[luv]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua
[popen]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua
[sys]: https://github.com/JBlaschke/luash/blob/master/sh/sys.lua
[stack]: https://github.com/JBlaschke/luash/blob/master/sh/stack.lua
[index_module]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L445
[command_fn]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L247
[Command]: https://github.com/JBlaschke/luash/blob/master/sh/command.lua#L371
[execute]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L196
[pipe_run]: https://github.com/JBlaschke/luash/blob/master/sh/pipe.lua#L63
[backend_run]: https://github.com/JBlaschke/luash/blob/master/sh/backend/init.lua#L249
[make_result]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L136
[result_index]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L123
[install]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L374
[preload]: https://github.com/JBlaschke/luash/blob/master/sh/backend/init.lua#L292
[load_pcall]: https://github.com/JBlaschke/luash/blob/master/sh/sys.lua#L26
[set_runner]: https://github.com/JBlaschke/luash/blob/master/sh/command.lua#L341
