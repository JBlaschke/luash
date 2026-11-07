# Reference code (frozen)

`sh/` holds the seven files produced in the design discussion that led to
`../DESIGN.md`, copied byte for byte from that discussion's last version of
each file. They are a starting point for the work packages in `../PLAN.md`,
not the deliverable: read them for the mechanics (fork and dup2 dance,
luv pipe handling, popen strategies) and rewrite them in the layout of
`DESIGN.md` section 2, in the code style of `AGENTS.md`, with the defects
below fixed. Never edit the files here and never copy them into `sh/`
unchanged.

| file | becomes | state |
|---|---|---|
| `stack.lua` | `sh/stack.lua` | fine; `Stack:new()`, `push`, `pop`, `size` |
| `args.lua` | `sh/command.lua` | flattening logic only; the Command and Pipeline types are new |
| `pipe.lua` | `sh/pipe.lua` | dispatcher idea only; platform table, capabilities and config are new |
| `pipe_posix.lua` | `sh/backend/posix.lua` | fork/exec mechanics; the I/O loop is replaced |
| `pipe_luv.lua` | `sh/backend/luv.lua` | closest to final; spawn-failure handling changes |
| `pipe_popen.lua` | `sh/backend/popen.lua` | strategy names and shell quoting; temp-file scheme is replaced |
| `init.lua` | `sh/init.lua` | Result metatable, builtins and `install()`; config, aliases and errors change |

All seven parse (`luac -p`). The backend files share no interface with
`DESIGN.md` section 4 yet: they export `pipe_simple(input, cmd, args,
verbose)` returning `status, cause, stdout, stderr`, while the new contract
is `run(argv, input, opts)` returning a table.

## Measured behaviour (lua-regolith, Lua 5.5.1, macOS)

The existing `tests/test.lua` was run against this code with each backend
selected through `sh.set_backend`:

| backend | result |
|---|---|
| posix | all pass except "Check Version" (string is `LuaSH 2.0.0`); `backend_name()` returns nil because the module has no `name` field |
| luv | all pass except "Check Version" |
| popen, standard | all pass except "Check Version" |
| popen, basic | all pass except "Check Version" |
| popen, minimal | also fails every test that feeds input (input is discarded by design) |

`init.lua` cannot be loaded at all on an interpreter without luaposix,
because of its unconditional `require("posix")`.

## Defects

The full list, with the fix for each, is `DESIGN.md` section 10. In short:
hard luaposix dependency in `init.lua`; `sh.__verbose` and
`sh.__raise_errors` silently ignored; empty error messages; stdin written
in one blocking call (deadlock above the pipe buffer size) and SIGPIPE not
ignored (the host dies with status 141); `assert` in the forked child after
a failed `execp`; verbose output mangled (`print(buf:sub(1, -2))`); `error()`
on `uv.spawn` failure; temp files opened then chmod-ed (race, one process
per file), names from `os.clock()` and an unseeded `math.random`; `false`
flag values emitted as flags; nondeterministic flag order; no `name` field
in the posix module.
