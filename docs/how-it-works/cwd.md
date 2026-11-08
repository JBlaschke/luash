# Working directory

## The builtins

`cd`, `pushd`, `popd` and `print` are not programs: [`sh/init.lua`][init]
implements them, and [`index_module`][index_module] returns them for those
names (the list is [`__index_ignore_function`][ignore]; `sh.install()`
consults the same list for globals). Each parses its arguments with
[`command.parse`][parse] and returns a [`passthrough`][passthrough] Result:
the stdout, stderr and status of the Results it was given, with the last
one's Pipeline. That is why a builtin is a neutral stage: in
`sh.echo("x"):cd("tests"):cat()`, `cat` still reads `x`.

[`cd(dir)`][cd] asks the backend to change directory and, when that fails,
returns the Result with `cd: The directory '...' does not exist` in
`__stderr` and 1 in `__exitcode`; the builtins never raise.
[`pushd`][pushd] remembers the current directory on
[`sh.PUSHD_STACK`][stack] before changing, and [`popd`][popd] returns to
the top entry.

## The backend owns the directory

The design makes the working directory the backend's
([section 4](../DESIGN.md#4-backend-contract)): the contract has
`chdir(dir)` and `getcwd()`, the registry forwards to them
([`backend.chdir`][backend_chdir] checks that `dir` is a non-empty
string), and `run` takes an optional `cwd` for one run only, which the
public API never sets.

- **posix** and **luv** call [`posix.chdir`][posix_chdir] and
  [`uv.chdir`][luv_chdir]: the directory of the whole process changes, as
  in a shell, and Lua's own `io.open` follows.
- **popen** has no `chdir`. [`chdir`][popen_chdir] runs
  `cd -P <old> && cd -P <dir> && pwd -P` through the shell
  ([`RESOLVE_DIR`][resolve_dir]), which checks that the directory can be
  entered and resolves `..` and symlinks, then remembers the result. Every
  later [`run`][popen_run] prefixes its command with
  `cd -P <dir> || exit 127`, and [`getcwd`][popen_getcwd] returns the
  remembered path. The emulation covers the programs LuaSH runs only: after
  `sh.cd("tests")` under popen, `io.open("file")` still opens it in the
  process's directory.

That difference is the one place where the backends show in ordinary use.
The [design](../DESIGN.md#63-popen-shbackendpopenlua) accepts it because a
real `chdir` needs a C module, which popen exists to avoid.

## Within one run

The `cwd` option of `run`, when a caller of the backend sets it, is
entered in the child only: posix calls `chdir` after the fork
([`exec_child`][exec_child]), luv passes the `cwd` spawn option, and popen
adds the `cd` prefix. A directory that cannot be entered is a start
failure, exit status 127 with a message, like a program that is not found.
The contract test exercises this ([testing](testing.md)).

[init]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua
[index_module]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L445
[ignore]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L349
[parse]: https://github.com/JBlaschke/luash/blob/master/sh/command.lua#L257
[passthrough]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L265
[cd]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L287
[stack]: https://github.com/JBlaschke/luash/blob/master/sh/stack.lua
[pushd]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L307
[popd]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L322
[backend_chdir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/init.lua#L257
[posix_chdir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L316
[luv_chdir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L189
[popen_chdir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L911
[resolve_dir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L267
[popen_run]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L972
[popen_getcwd]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L927
[exec_child]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L114
