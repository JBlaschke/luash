# Pipes in each backend

A pipeline has two levels; only one of them uses operating-system pipes.

## Between stages: a string handoff

`sh.seq(1, 10):grep("5"):wc("-l")` runs three programs one after another:
[`Pipeline:run`][pipeline_run] runs each stage to completion, and the
[`runner`][runner] gives the next stage the Result's whole stdout as one
string. No pipe connects two stages. [Section 3.4](../DESIGN.md#34-command-and-pipeline) chose
this so that every Result is complete, with stdout, stderr, exit status and
provenance per stage, and a backend only ever runs one program with a known
input.

## Inside a stage

Within a stage the backend connects one program's stdin, stdout and stderr
([section 6](../DESIGN.md#6-backend-designs)).

### posix: fork, four pipes, one poll loop

[`open_pipes`][open_pipes] creates pipes for stdin, stdout, stderr and a
status byte; [`spawn`][spawn] marks the parent's ends close-on-exec and
forks. The child ([`exec_child`][exec_child]) moves its ends onto
descriptors 0, 1 and 2 and calls `execp`; if that fails it writes a byte
to the status pipe and exits 127. The parent's [`pump`][pump] is one
`posix.poll` loop: it writes the input in slices of up to 64 KiB as the
child drains its non-blocking stdin, and reads stdout and stderr in 4 KiB
chunks as they arrive, so no input or output size can deadlock. SIGPIPE is
ignored during the run ([`run`][posix_run]): a child that quits early gives
EPIPE instead of killing the host. [`reap`][reap]
waits for the child and reads the status pipe: a byte means that exec
failed, EOF that it succeeded and close-on-exec closed the pipe. Design:
[section 6.1](../DESIGN.md#61-posix-shbackendposixlua).

### luv: uv.spawn and the libuv loop

[`run`][luv_run] creates three `uv.new_pipe` handles and passes them as
the `stdio` of [`uv.spawn`][uv_spawn]. [`feed`][feed] writes the whole
input with one `write` and shuts the pipe down, so the child sees EOF;
[`drain`][drain] reads both output pipes. [`uv.run("once")`][uv_run_once]
runs until the process has exited and both outputs hit EOF; libuv
interleaves the writes and reads. A signal handle from
[`catch_sigpipe`][catch_sigpipe] swallows SIGPIPE while input is written.
An error in a callback kills the child, closes every handle and is raised
again afterwards. Design: [section 6.2](../DESIGN.md#62-luv-shbackendluvlua).

### popen: one pipe and a shell string

`io.popen` gives one pipe, the child's stdout, which
[`execute`][popen_execute] reads in 4 KiB chunks. The shell string that
[`render_sh`][render_sh] builds arranges the rest: `exec <argv>` in a
subshell, every argument quoted, and the strategy
([`STRATEGIES`][strategies]) decides where stdin, stderr and the exit
status go.

| Strategy | stdin | stderr | exit status |
|---|---|---|---|
| `shmem` | temp file under `/dev/shm` | temp file | temp file, written by the shell |
| `standard` | temp file under the temp root | temp file | temp file |
| `basic` | on the command line, piped in by `printf '%s' '<input>'` ([`printf_input`][printf_input]) | merged, `2>&1` | `h:close()`, Lua 5.2 and newer |
| `minimal` | `/dev/null` | merged | `h:close()` |

The temp files live in a private directory ([`private_dir`][private_dir]:
`mkdir -m 700` plus a secret marker) and are removed after each run. stdout streams while the program runs; stderr comes
from its file after exit, in one piece. Design:
[section 6.3](../DESIGN.md#63-popen-shbackendpopenlua).

`sh.capabilities()` reports these differences
([section 5](../DESIGN.md#5-capabilities)); [`pipe.run`][pipe_run] refuses
input for a backend whose `stdin` capability is false.

[pipeline_run]: https://github.com/JBlaschke/luash/blob/master/sh/command.lua#L531
[runner]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L212
[open_pipes]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L97
[spawn]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L140
[exec_child]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L114
[pump]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L190
[posix_run]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L342
[reap]: https://github.com/JBlaschke/luash/blob/master/sh/backend/posix.lua#L254
[luv_run]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L216
[uv_spawn]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L250
[feed]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L130
[drain]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L147
[uv_run_once]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L310
[catch_sigpipe]: https://github.com/JBlaschke/luash/blob/master/sh/backend/luv.lua#L108
[popen_execute]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L702
[render_sh]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L323
[strategies]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L74
[printf_input]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L302
[private_dir]: https://github.com/JBlaschke/luash/blob/master/sh/backend/popen.lua#L591
[pipe_run]: https://github.com/JBlaschke/luash/blob/master/sh/pipe.lua#L63
