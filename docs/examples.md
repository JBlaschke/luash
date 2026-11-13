# Examples

The scripts in [`examples/`](https://github.com/JBlaschke/luash/tree/main/examples)
run from a clone of the repository without installing anything:

```bash
git clone https://github.com/JBlaschke/luash.git && cd luash
```

```bash
examples/run_all.sh                # every example, with `lua`
```

```bash
LUA_PATH='./?/init.lua;./?.lua;;' lua examples/01_basics.lua
```

`examples/run_all.sh luajit` picks another interpreter, and
`LUASH_BACKEND=popen examples/run_all.sh` runs everything on the popen
backend. With the library installed, drop the `LUA_PATH`. The output below
comes from a macOS machine with luaposix and luv installed; user names,
directories and backend names differ on yours.

## 1. Programs as functions

```lua
--8<-- "examples/01_basics.lua"
```

```text
Darwin
hello world
I am <your user name>
line one
line two
0
true
got	1
got	2
got	3
100
```

## 2. Pipelines

```lua
--8<-- "examples/02_pipelines.lua"
```

```text
c
b
a
1
4
5
Applications
Library
System
16
{ seq 1 10; seq 20 25; } | wc -l
HELLO
```

## 3. Flags, partial commands and tricky names

```lua
--8<-- "examples/03_flags.lua"
```

```text
9
10
100
tar -c --file=site.tar --verbose docs
ls -l --color=never
bd6986a Merge pull request #14 from JBlaschke/claude/backend-registry
0	function
sh
type is a shell builtin
```

## 4. Commands as data

```lua
--8<-- "examples/04_commands_as_data.lua"
```

```text
ls -l /tmp -a
ls	4
seq 1 10 | wc -l
10
sort | head -n 1
a
echo 'it'\''s' 'two words'
seq 1 10 | grep 5 | wc -l
git log	/	git log --oneline
```

## 5. Errors

```lua
--8<-- "examples/05_errors.lua"
```

```text
false	ls: /no/such/directory: No such file or directory
false	sh -c 'exit 3': exit status 3
grep found nothing: status 1
127
sh: no_such_program_xyz: No such file or directory

1	cd: The directory '/no/such/directory' does not exist
```

The second message has no file position because `pcall` called the
function directly; raised from a script line, the message starts with that
line. The wording of the `127` message depends on the backend.

## 6. Trace, verbose output and the sink

```lua
--8<-- "examples/06_verbose_trace.lua"
```

stderr and stdout interleaved as a terminal shows them:

```text
+ seq 1 3
+ seq 1 3 | wc -l
+ sh -c 'echo out; echo err >&2'
out
err
trace: + echo a b
stdout: a b
```

## 7. Directories

```lua
--8<-- "examples/07_directories.lua"
```

```text
<the clone>
<the clone>/tests
init.lua
luv.lua
popen.lua
posix.lua
<the clone>
1	cd: The directory '/no/such/directory' does not exist
passed through
```

## 8. Backends

```lua
--8<-- "examples/08_backends.lua"
```

```text
in use:    posix
available: posix luv popen
exitcode	true
name	posix
separate_stderr	true
signals	true
stdin	true
streaming	true
now using popen/standard
still works
out
err
posix	auto	auto
```

## 9. A backend of your own

```lua
--8<-- "examples/09_custom_backend.lua"
```

```text
logging
[logging] seq 1 3 (0 bytes of input)
[logging] wc -l (6 bytes of input)
3
```

[Testing and your own backend](how-it-works/testing.md) explains the
contract this backend implements and how to test one.

## 10. Environment variables

```lua
--8<-- "examples/10_environment.lua"
```

```text
unset unset
red 3
blue unset
red 3
unset unset
UTC
1	popenv: the environment stack is empty
```

[Environment variables](how-it-works/environment.md) says what each
backend does with a variable, and what the popen backend cannot do.
