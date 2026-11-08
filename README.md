# sh: Lua command-line scripting made easy

Tiny library for shell scripting with Lua (inspired by
[Python's sh module](https://pypi.org/project/sh/)). This is a rewrite of
[luash](https://github.com/zserge/luash) that keeps stdout and stderr apart,
reports exit status and signals, and implements `cd`, `pushd`, and `popd`.

It runs on Lua 5.1 to 5.5 and LuaJIT and needs no C module. Programs are
started through [luaposix](https://luarocks.org/modules/gvvaughan/luaposix)
or [luv](https://luarocks.org/modules/luvit/luv) when one of them is
installed, and through Lua's own `io.popen` otherwise (see
[Backends](#backends-and-shconfig)).

The [documentation site](https://jblaschke.github.io/luash/) has runnable
[examples](https://jblaschke.github.io/luash/examples/) and a short page on
each part of [how the library works](https://jblaschke.github.io/luash/how-it-works/architecture/),
with links into the design document and the code.

## Install

Via luarocks:

```bash
luarocks install sh
```

That installs the latest release from luarocks.org. To install the version in
a clone of this repository, run `luarocks make rockspec/sh-scm-3.rockspec`
there.

Without luarocks, copy the single file `standalone/sh.lua` into your project,
somewhere on `package.path`, and `require("sh")` as usual. It holds the whole
library. It is generated from `sh/` by `make standalone`; never edit it.
Every [release](https://github.com/JBlaschke/luash/releases) carries that
file as the asset `sh.lua`, so one version is one download:

```bash
curl -LO https://github.com/JBlaschke/luash/releases/download/v2.0.0/sh.lua
```

`releases/latest/download/sh.lua` is the newest release.

luaposix and luv are optional. Either one gives a faster backend that streams
stderr separately and reports signals:

```bash
luarocks install luaposix   # or: luarocks install luv
```

## Simple usage

Every program on `PATH` (shell builtins are different, more on that later)
can be called as a global function. All the arguments passed into the
function become command arguments.

```lua
local sh = require('sh')
sh.install() -- make shell bindings available to the global namespace

local wd = tostring(pwd()) -- calls `pwd` and returns its output as a string

local files = tostring(ls('/tmp')) -- calls `ls /tmp`
for f in string.gmatch(files, "[^\n]+") do
    print(f)
end
```

Note that `sh.install()` is needed to make all shell commands into global
functions. If `sh.install()` is omitted, then the `sh` namespace remains
isolated to the module. In that case, you can call any shell command using
`sh.<command name>(<args>)` (e.g. `sh.pwd()`).

## Command input and pipelines

If a command argument is a table which has an `__input` field, it is used as
the command's input (stdin). Multiple arguments with input are allowed; they
are concatenated.

Each command function returns a structure that contains the `__input` field,
so nested functions can be used to make a pipeline.

The commands do not run in parallel: the innermost command runs to
completion, its output is collected, and then the next command runs with that
output as its stdin, and so on.

```lua
local sh = require('sh')
sh.install()

local words = 'foo\nbar\nfoo\nbaz\n'
local u = uniq(sort({__input = words})) -- like $(echo ... | sort | uniq)
print(u) -- prints "bar", "baz", "foo"
```

Pipelines can be also written as chained function calls. Lua allows to omit
parens, so the syntax really resembles unix shell:

```lua
-- $ ls /bin | grep $filter | wc -l

-- normal syntax
wc(grep(ls('/bin'), filter), '-l')
-- chained syntax
ls('/bin'):grep(filter):wc('-l')
-- chained syntax without parens
ls '/bin' : grep(filter) : wc '-l'
```

**Important**: All function calls after a `:` occur inside of the `sh` module.
Thus, if `sh` hasn't been installed into the global namespace, then `sh` must
be prepended to _only the first_ function call in a "pipe". E.g. the last
statement in the example above becomes:

```lua
local sh = require('sh')
-- note: __not__ calling `sh.install()`
sh.ls '/bin' : grep(filter) : wc '-l'
```

## Command output can be concatenated using `..`

Output from commands can be concatenated using the `..` operator:

```lua
print("I am: "..whoami())
print(ls "-l":wc "-l".." files/folders found!")
```

## Partial commands and commands with tricky names

You can use `sh.command` to construct a command function, optionally
pre-setting the arguments:

```lua
local sh = require('sh')

local truecmd = sh.command('true') -- because "true" is a Lua keyword
local chrome = sh.command('google-chrome') -- because '-' is an operator

local gittag = sh.command('git', 'tag') -- gittag(...) is same as git('tag', ...)

gittag('-l') -- list all git tags
```

`sh` can be used as a function as well, it's an alias to `sh.command()`

## Commands and pipelines as data

`sh.Command` builds a command without running it, and `sh.Pipeline` chains
commands. Both print as the shell line they stand for, and run on demand:

```lua
local sh = require('sh')

local c = sh.Command('ls', '-l')     -- nothing runs yet
c:arg('/tmp', '/var')                -- more positional arguments
c:flag('color', 'auto')              -- appends --color=auto
c:flag('a')                          -- appends -a
c:flag('h', false)                   -- appends nothing
print(c)                             -- ls -l /tmp /var --color=auto -a

local p = sh.Command('seq', 1, 10):pipe(sh.Command('wc', '-l'))
print(p)                             -- seq 1 10 | wc -l
print(p:run())                       -- 10

local q = sh.Pipeline(sh.Command('ls', '/bin'), sh.Command('sort', '-r'))
q:pipe(sh.Command('head', '-n', 3))
print(q)                             -- ls /bin | sort -r | head -n 3
print(sh.Command('grep', 'b'):input('a\nb\nc\n'):run())  -- b
```

`sh.Command(name, ...)` takes the same arguments as `sh.name(...)`.
`c:argv()` and `p:commands()` return new tables of the argument vector and of
the stages. `c:run()` returns the same Result as calling the command
directly; `p:run()` runs the stages left to right and returns the Result of
the last one. On Lua 5.3 and newer, `sh.Command('ls') | sh.Command('wc', '-l')`
builds a Pipeline too.

Arguments that contain anything but letters, digits and `-._/=:@%+,` print in
single quotes: `sh.Command('echo', "it's")` prints as `echo 'it'\''s'`. The
printed form is for reading and logging: the posix and luv backends pass the
arguments to the program directly, without a shell.

Every Result remembers the pipeline that produced it in `__pipeline`:

```lua
local sh = require('sh')

local r = sh.seq(1, 10):grep(5):wc('-l')
print(r.__pipeline)  -- seq 1 10 | grep 5 | wc -l

r = sh.wc(sh.seq(1, 10), sh.seq(20, 25), '-l')
print(r.__pipeline)  -- { seq 1 10; seq 20 25; } | wc -l
```

## Return type

Every command returns a table with: `__stdout`, `__stderr`, `__input`,
`__exitcode`, `__signal` and `__pipeline`. The table also has metatable
fields `__index`, `__tostring`, and `__concat`. These always exist, and allow
chaining using the `:` operator. `__input` is used for command chaining -- a
command that is "neutral" (like `cd`) will pass all inputs through, while the
usual POSIX pipe is accomplished by setting `__input` to `__stdout` from the
previous command.

`tostring(r)` is the trimmed stdout. When the command wrote to stderr, it is
`O: <stdout>`, `E: <stderr>` and the exit status, on three lines.

## Accessing `stdout` and `stderr`

The `__stdout` and `__stderr` fields contain stdout and stderr. Accessing
them directly can yield messy code -- so the `sh.stdout(cmd)` and
`sh.stderr(cmd)` commands exist to allow for cleaner code. These simply return
the corresponding field -- eg. `sh.stdout(cmd) == cmd.__stdout`.

## Exit status and signal values

Each command function returns a table with `__exitcode` and `__signal` fields.
`__exitcode` is the exit status, and zero means the command succeeded. When
the program was killed by a signal, `__signal` is the signal number and
`__exitcode` is 127; otherwise `__signal` is 0.

The popen backend cannot see signals: a program killed by signal N reports
exit status 128 + N, as in a shell, and `__signal` is 0. Its `basic` and
`minimal` strategies take the exit status from `io.popen(...):close()`, which
reports nothing on Lua 5.1 and LuaJIT, so there `__exitcode` is always 0.
`sh.capabilities()` tells which case applies (see below).

## Command arguments as a table

Key-value arguments can be also specified as argument table pairs:

```lua
local sh = require('sh')
sh.install()

-- $ somecommand --format=long --interactive -u=0
somecommand({format="long", interactive=true, u=0})
```

It becomes handy if you need to toggle or modify certain command line
arguments without manually changing the arguments list. The rules:

- One-letter keys give `-k`, longer keys `--key`.
- `true` gives the bare flag, and `false` gives nothing.
- A string or number gives `key=value` (`--key=` for the empty string).
- The flags follow the positional arguments of the same table, sorted by key,
  so the command line is the same on every run.

When the order of flags matters, write them as positional strings or use
`sh.Command(...):flag(...)`, which keeps the order of the calls.

## Managing errors

By default, a command that does not exit with status 0 raises a Lua error.
When the command wrote to stderr, the message is that text, trimmed. On macOS:

```lua
local sh = require "sh"
sh.ls("/missing")
```

```
lua: test.lua:2: ls: /missing: No such file or directory
stack traceback:
	[C]: in function 'error'
	...
```

Otherwise the message names the pipeline and how it ended:
`sh -c 'exit 3': exit status 3`, `sh -c 'kill -9 $$': killed by signal 9`, or
`seq 1 3 | sh -c 'cat >/dev/null; exit 4': exit status 4`.

The popen backend's `basic` and `minimal` strategies merge stderr into
stdout, so their messages always take this form (`ls /missing: exit status
1`). On Lua 5.1 and LuaJIT these two strategies see no exit status, so
nothing raises there.

A program that cannot be started, because it is not on `PATH` or is not
executable, is reported the way a shell reports it: exit status 127 and a
message on stderr. So `sh.asdf()` (assuming `asdf` is not a program) raises
an error like `sh: asdf: No such file or directory`; the exact wording depends
on the backend.

Set `sh.config.raise_errors` to false (or `sh.__raise_errors`, the name from
1.x) to get the Result back instead, with the failure in `__exitcode` and
`__stderr`:

```lua
local sh = require "sh"
sh.config.raise_errors = false
local cmd = sh.asdf()
print(cmd)
```

prints, with the posix backend (the stderr text differs between backends):

```
O: 
E: sh: asdf: No such file or directory
127
```

The builtins (`cd`, `pushd`, `popd`, `print`) never raise; they report a
failure through `__exitcode` and `__stderr`.

## Verbose output and tracing

With `sh.config.verbose = true` (or `sh.__verbose = true`), each command's
output is written while the command runs: stdout to `io.stdout` and stderr to
`io.stderr`, byte for byte, flushed after every chunk. Progress bars that
redraw a line with `\r`, such as those of `curl` and `wget`, animate as they
would in a terminal. The Result still holds the whole output.

To send that output somewhere else, set `sh.config.sink` to a function. It
receives the stream name (`"stdout"`, `"stderr"`, or `"trace"`) and the chunk:

```lua
local sh = require('sh')
sh.config.verbose = true
sh.config.sink = function(stream, chunk)
    io.write("[", stream, "] ", chunk)
end
sh.sh("-c", "echo out; echo err >&2")
-- [stdout] out
-- [stderr] err
```

With `sh.config.trace = true`, a line `+ <pipeline>` goes to stderr (or to the
sink) before each command runs, showing every stage up to that command, like
`set -x` in a shell:

```lua
local sh = require('sh')
sh.config.trace = true
sh.seq(1, 3):wc("-l")
-- + seq 1 3
-- + seq 1 3 | wc -l
```

On the popen backend, stderr arrives in one piece after the command has
exited, and the `basic` and `minimal` strategies merge it into stdout.

## Backends and `sh.config`

| backend | needs | stdin | stderr | streaming | signals |
|---|---|---|---|---|---|
| `posix` | luaposix | yes | separate | yes | yes |
| `luv` | luv | yes | separate | yes | yes |
| `popen` | `io.popen` only | depends on the strategy | depends on the strategy | stdout | no |

By default (`"auto"`), sh uses the first available backend in the order of
the platform: `posix`, `luv`, `popen` on Linux, macOS and the BSDs; `luv`,
`popen` on Windows; `luv`, `posix`, `popen` on Android. The backend is
selected once, when `require("sh")` runs, and again only by
`sh.set_backend`; every command and `cd` then goes to the backend in use.

```lua
local sh = require('sh')
print(sh.backend_name())                          -- posix
print(table.concat(sh.available_backends(), " ")) -- posix luv popen
sh.set_backend("popen", {strategy = "standard"})  -- raises if unavailable
for k, v in pairs(sh.capabilities()) do print(k, v) end
```

`sh.capabilities()` describes the backend in use: `name`, `strategy` (popen
only), and the booleans `stdin` (input can be passed), `separate_stderr`,
`streaming` (output arrives while the program runs), `exitcode` (the exit
status is known) and `signals`. `sh.set_backend` also accepts a table that
implements the backend contract, for a backend of your own: a `name` and
the functions `available`, `capabilities`, `configure`, `run`, `chdir` and
`getcwd`, as in `tests/backend_fake.lua`.

The settings, with their defaults:

```lua
sh.config = {
    verbose      = false,   -- stream output live
    trace        = false,   -- print "+ <pipeline>" before each command
    raise_errors = true,    -- error() when a command fails
    backend      = "auto",  -- "auto" | "posix" | "luv" | "popen"
    popen        = {
        strategy = "auto",  -- "auto" | "shmem" | "standard" | "basic" | "minimal"
        tmpdir   = nil,     -- root for temp files; nil: TMPDIR, TMP, TEMP, /tmp
    },
    sink         = nil,     -- function(stream, chunk) for verbose and trace
}
```

`verbose`, `trace`, `raise_errors` and `sink` are read at every command.
`backend` and `popen` are read when sh loads, when a table is assigned to
`sh.config`, and by `sh.set_backend()`, which without an argument selects
the backend that `sh.config` names: after `sh.config.backend = "popen"`,
call `sh.set_backend()`.

The environment variables `LUASH_BACKEND` and `LUASH_POPEN_STRATEGY` override
`"auto"` for the backend and the popen strategy. They are read once, when sh
loads, and exist for test runs and operators; code should set `sh.config` or
call `sh.set_backend`.

The popen backend runs every command through `/bin/sh` and gets the rest from
temp files or the command line. Its strategies, from most to least capable:

| strategy | stdin | stderr | exit status | needs |
|---|---|---|---|---|
| `shmem` | temp file | separate | yes | Linux, writable `/dev/shm` |
| `standard` | temp file | separate | yes | a writable temp directory |
| `basic` | on the command line | merged into stdout | Lua 5.2+ | nothing |
| `minimal` | none (`/dev/null`) | merged into stdout | Lua 5.2+ | nothing |

`"auto"` picks the first that works, and never `basic` while a file strategy
works. The temp files live in a private directory (`luash-<pid>-<random>`,
mode 700) that is removed when the Lua state closes; a script that ends with
`os.exit(code)` skips that, so call `os.exit(code, true)` on Lua 5.2 and newer
and LuaJIT. **`basic` puts the input on the command line**, where every user
of the machine can read it in `ps`, and where the system limits its size
(128 KiB on Linux). Under `minimal`, a command given input raises an error
instead of silently dropping it.

## Changing directories

`sh.cd(dir_name)` changes the current directory to `dir_name`. It can be
chained using the `:` operator. Eg.

```lua
local sh = require "sh"
sh.cd("tests") : ls() : print()
```

Note: the `sh.cd` command does return a metatable with an `__index` function,
the same way as any other `sh` functions, but it passes `__input` through --
acting as a neutral step of a "pipe".

`sh` also emulates `pushd` and `popd`, keeping track of the stack of
directories visited (using `sh.PUSHD_STACK`). E.g. the program:

```lua
local sh = require "sh"
print("-- 1")
sh.pwd() : print()
print("-- 2")
sh.pushd("tests") : pwd() : print()
print("-- 3")
sh.popd() : pwd() : print()
```

Has the output:

```
-- 1
/home/luash
-- 2
/home/luash/tests
-- 3
/home/luash
```

Note how `sh.popd()` returns to the previous directory. This way `pushd` and
`popd` can be used to bracket commands -- eg:

```lua
sh.pushd(my_dir) : my_cmd(my_args) : popd()
```

`cd` belongs to the backend: the posix and luv backends change the directory
of the process. The popen backend has no `chdir` and emulates `cd`: it checks
the directory, remembers it, and runs every later command in it. The emulated
directory applies to the commands that sh runs only, not to Lua itself:
`io.open("file")` still opens `file` in the directory the process started in.

## Upgrading from 1.x

- luaposix is no longer required. `require("sh")` now loads the module
  directory `sh/` that luarocks installs, or the single file
  `standalone/sh.lua` that replaces the old `sh.lua`.
- Table flags are emitted sorted by key; 1.x used the table's order, which
  could change from run to run. Use positional strings or `:flag()` where the
  order matters.
- A flag set to `false` is left out; 1.x emitted it.
- `sh.PIPES`, `sh.launch_pipe_simple` and `sh.collect_pipes` are gone (they
  never worked).
- `sh.__verbose` and `sh.__raise_errors` still work; they read and write
  `sh.config.verbose` and `sh.config.raise_errors`.
- Verbose output is passed through unchanged, with stderr on stderr; 1.x
  printed each 4 KiB chunk without its last byte and with a newline added.
- A program that cannot be started gives exit status 127 and a message,
  instead of a traceback from the forked child.
- An error with an empty stderr names the pipeline and the exit status.
- Results have a `__pipeline` field, and `sh.Command`, `sh.Pipeline`,
  `sh.config`, `sh.set_backend`, `sh.backend_name`, `sh.available_backends`
  and `sh.capabilities` are new.
- `sh.version` is `"Automatic Shell Bindings for Lua / LuaSH 2.0.0"`.

## Questions

### The Lua Language Server Doesn't Recognize Shell Commands

You're using the [Lua Language Server](https://github.com/sumneko/lua-language-server)
within your favorite editor, but some `sh` commands still show up as incorrect?
There are two possible solutions: i) you need to install `lsf`

```bash
luarocks install luafilesystem
```

and; ii) the lua language server support currently is a little buggy.

### Does this work on Windows?

Maybe. On Windows sh prefers the luv backend, which starts programs through
libuv, and falls back to `io.popen` with `cmd.exe` syntax. Neither has been
tested on Windows, since I don't have access to a Windows machine (nor do I
have any experience with Windows...). If you try it, please open an issue
with what worked and what didn't; I am also happy to work with any Windows
experts.

## Origins: How is this related to Luash, and sh v1?

The original [luash](https://github.com/zserge/luash) is great! But the 
problem is that I was missing `cd` support, as well as separate pipes for
`stdout` and `stderr`. Also -- and more importantly -- the original `luash`
stores the intermediate results in a `:` "pipe" to a temporary file. I 
use `sh` to coordinate scripts on a shared system, where `stdout` and
`stderr` can contain privileged information. A crash before any temporary
files are cleaned up could leak private information.

After a few years working with the initial re-write a long list of issues
emerged + many workarounds. This was starting to become unbearable, leading
us to version 2: a full re-write (by Claude) in order to introduce 3 major
improvements:
1. Tidy up configuration
2. Introduce a `luv` backend
3. Introduce a `popen` backend

The `posix` and `luv` backends use pipes only. The `popen` backend's `shmem`
and `standard` strategies do use temporary files, in a directory that only
your user can read, removed after each command; install luaposix or luv where
that matters. In a way, the `popen` backend is a return to
[zsegre's](https://github.com/zserge) vision (which is simplicity), but with
more security and performance-oriented alternatives.

## License

Code is distributed under the MIT license.
