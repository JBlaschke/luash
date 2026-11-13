# Environment variables

## The builtins

`pushenv` and `popenv` are builtins like `pushd` and `popd`
([working directory](cwd.md#the-builtins)): [`sh/init.lua`][init]
implements them, they chain with `:`, and they pass the Results they are
given through. `pushenv` changes variables for the commands that follow
and remembers what they were; `popenv` puts them back.

[`pushenv(...)`][pushenv] reads its arguments with
[`command.parse_env`][parse_env]:

- a string is `"NAME=value"`, split at the first `=`;
- a table gives one variable per string key: a string or a number is the
  value, and `false` removes the variable. Its array entries are read as
  arguments again, so strings and tables nest;
- `nil` and `false` are skipped, and where a variable is named twice the
  later one counts, so `sh.pushenv(defaults, overrides)` works;
- a Result, as in a chain, is not read for variables: it passes through.

Anything else raises at the line of the call, like a malformed argument
of a command ([`add_variable`][add_variable]): a string without `=`, an
empty name, a NUL byte in a name or a value, and `true` or a table as a
value.

The variables then change one by one through the backend, in byte order
of their names whatever the order of the arguments, and the value each
had before goes into a frame on [`sh.PUSHENV_STACK`][env_stack], with
`false` for a variable that was not set. When the backend refuses one,
`pushenv` puts back those it had changed, pushes no frame, and returns
the Result with `pushenv: <name>: <reason>` in `__stderr` and 1 in
`__exitcode`. A `pushenv` takes effect whole or not at all.

[`popenv()`][popenv] takes the top frame and gives its variables their
earlier values, the last one changed first ([`restore_env`][restore_env]).
With no frame left it reports `popenv: the environment stack is empty`.
A `pushenv()` that names no variable pushes an empty frame, so every
`pushenv` that succeeded has its `popenv`.

## The backend owns the environment

The environment belongs to the backend, as the directory does. Next to
the six functions of the [contract](../DESIGN.md#4-backend-contract), a
backend may have two more:

```lua
function B.setenv(name, value)  -- value nil removes; -> true | nil, reason
function B.getenv(name)         -- -> the value the programs get, or nil
```

The registry forwards to them ([`backend.setenv`][backend_setenv],
[`backend.getenv`][backend_getenv]) after checking the name and the
value. They are not part of the contract, so a backend written for the
six functions still loads: without `setenv`, `pushenv` reports
`backend <name> cannot change the environment`, and without `getenv` the
registry asks `os.getenv`.

- **posix** calls [`posix.stdlib.setenv`][posix_setenv], and **luv**
  [`uv.os_setenv` and `uv.os_unsetenv`][luv_setenv]: the environment of
  the whole process changes, as with `export` in a shell. Every program
  started afterwards inherits it, whoever starts it, and Lua's
  `os.getenv` reads it. Under luv on Windows, which is untested, the C
  library keeps a copy of the environment that `os.getenv` reads and
  `uv.os_setenv` does not change, so the backend asks `uv.os_getenv`.
- **popen** cannot do that: standard Lua has `os.getenv` and nothing to
  set a variable with. [`setenv`][popen_setenv] remembers the variable
  instead ([`overrides`][overrides]), and every later [`run`][popen_run]
  gives the remembered variables to its program in the shell string
  ([`render_sh`][render_sh]):

    ```text
    ( unset -v OLD || exit 127; exec env 'CC=clang' 'NOTE=it'\''s' 'make' '-j4' )
    ```

    `unset -v` removes a variable and `env` sets the others, because a
    shell does not hand every assignment of its own to its children:
    bash takes an assignment to `RANDOM` as a seed and refuses one to
    `UID`. Through `env` each value arrives byte for byte.
    [`getenv`][popen_getenv] answers with the remembered value, else
    with that of the process. A variable set back to what the process
    has is forgotten, so without changes the shell string is the one of
    a run without `pushenv`.

## What the popen emulation does not cover

Like the emulated `cd`, the emulated environment applies to the programs
LuaSH runs, and to nothing else:

- `os.getenv` in Lua returns what the process started with, and so does
  everything else that reads the environment of the process: `io.popen`,
  `os.execute`, a C library.
- A name is one the shell can unset: letters, digits and `_`, not
  starting with a digit ([`VARIABLE`][VARIABLE]). `pushenv` reports any
  other name as a failure. posix and luv take every name without `=`.
- While a variable is set, a program whose name contains `=` cannot be
  started (exit status 127): `env` would read the name as one more
  variable.
- While a variable is set, `env` starts the program, so the message for
  a program that is not found comes from `env`, not from the shell.
- The variables that are set are part of the command line of every run,
  which the system caps: at 128 KiB on Linux, where posix and luv have
  that limit for each variable. A run whose command line is too long
  fails to start and says so
  ([pass large input](pipes.md#pass-large-input)).
- `PATH` cannot be removed: `pushenv({ PATH = false })` reports a
  failure. Once `PATH` is unset, bash and dash look for a program in the
  current directory, where posix and luv search the default path of the
  C library. Give `PATH` a value instead; the program is then looked up
  in it, as under the other backends.
- A variable that the shell refuses to unset fails every run with exit
  status 127 and the shell's message, until it is popped. bash refuses
  for `SHELLOPTS`, when the process has it exported.
- With `cmd.exe` on Windows, which is untested, the variables become
  `set "NAME=value" &` in front of the command, and `setenv` refuses an
  empty value and one that holds a double quote, a percent sign or a
  line break.

On every backend, a frame is put back through the backend in use at the
`popenv`. A script that switches backends between a `pushenv` and its
`popenv` leaves the environment of the first backend changed.

## How to

### Set variables for some commands

`pushenv` and `popenv` bracket a stretch, and chain like commands:

```lua
sh.pushenv({ CC = "clang", MAKEFLAGS = "-j4" })
sh.make()
sh.make("check")
sh.popenv()

sh.pushenv({ LC_ALL = "C" }):sort("names.txt"):popenv():print()
```

The calls nest, and each `popenv` undoes one `pushenv`:
`sh.PUSHENV_STACK:size()` is the depth.

### Remove a variable

`false` removes a variable for the commands; `popenv` gives it back:

```lua
sh.pushenv({ DISPLAY = false, SSH_AUTH_SOCK = false })
sh.git("fetch")
sh.popenv()
```

An empty string is a value: `{ NAME = "" }` sets `NAME` to the empty
string, which programs can tell from a variable that is not set.

### Set a variable for one command only

The `env` program does that by itself, with nothing to put back, on
every backend:

```lua
sh.env("LC_ALL=C", "sort", "names.txt")
```

### Keep the change local when a command raises

A command that raises between `pushenv` and `popenv` skips the `popenv`.
A helper that pops under an error as well keeps the change local:

```lua
local function with_env(vars, f, ...)
    local pushed = sh.pushenv(vars)
    if pushed.__exitcode ~= 0 then error(sh.stderr(pushed), 2) end
    local ok, result = pcall(f, ...)
    sh.popenv()
    if not ok then error(result, 0) end
    return result
end

with_env({ CC = "clang" }, sh.make, "-j4")
```

### Check that a `pushenv` worked

The builtins never raise for a variable that cannot be changed; read the
Result:

```lua
local r = sh.pushenv({ ["my.var"] = "x" })
if r.__exitcode ~= 0 then error(sh.stderr(r)) end
```

Under posix and luv this one succeeds. Under popen the message is
`pushenv: my.var: sh.popen.setenv: the shell takes a name of letters, digits and _ that does not start with a digit`,
and nothing was changed or pushed.

### Read what the commands get

Under posix and luv `os.getenv` follows `pushenv`; under popen it does
not. The registry answers for the programs on every backend:

```lua
local backend = require("sh.backend")

sh.pushenv({ EDITOR = "vi" })
print(os.getenv("EDITOR"))       -- vi under posix and luv, else as before
print(backend.getenv("EDITOR"))  -- vi
sh.popenv()
```

So does a program: `sh.sh("-c", 'printf %s "$EDITOR"')`.

### Support `pushenv` in a backend of your own

Give the table a `setenv(name, value)` that returns true, or nil and a
reason, and where `os.getenv` would be wrong a `getenv(name)`. A backend
that wraps another forwards both, as
[`examples/09_custom_backend.lua`][example09] does. `name` is a non-empty
string without `=` and NUL bytes, and `value` is a string without NUL
bytes, or nil to remove the variable; the registry checks both before
the call. [`tests/test_backend.lua`][test_backend] runs its environment
checks on a backend that has a `setenv`
([testing](testing.md#test-a-backend-of-your-own)).

[init]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua
[pushenv]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L356
[popenv]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L374
[restore_env]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L339
[env_stack]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L334
[parse_env]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L384
[add_variable]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L264
[backend_setenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L282
[backend_getenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L304
[posix_setenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L348
[luv_setenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L224
[popen_setenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L1031
[popen_getenv]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L1068
[popen_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L1111
[overrides]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L117
[VARIABLE]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L121
[render_sh]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L388
[example09]: https://github.com/JBlaschke/luash/blob/main/examples/09_custom_backend.lua
[test_backend]: https://github.com/JBlaschke/luash/blob/main/tests/test_backend.lua
