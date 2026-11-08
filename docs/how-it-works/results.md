# Results, errors and output

## The Result

Every command, builtins included, returns a table that
[`make_result`][make_result] builds with six fields
([section 3.5](../DESIGN.md#35-result-objects)): `__stdout`, `__stderr`,
`__exitcode`, `__signal`, `__input` and `__pipeline`. `__input` is what
the next stage of a chain reads: for a command it equals `__stdout`, for a
builtin it is the input that passed through. The metatable does three
things:

- [`__tostring`][result_tostring] is the trimmed stdout, or the three lines
  `O: <stdout>`, `E: <stderr>` and the exit status when the program wrote
  to stderr.
- [`__concat`][result_concat] lets `"I am " .. sh.whoami()` work.
- [`__index`][result_index] falls back to the module, which is what makes
  `r:grep("x")` a command call with `r` as its input. The six field names
  are answered with nil, never with a command.

`sh.stdout(r)` and `sh.stderr(r)` are the two fields as functions.

## Exit status and signals

`__exitcode` is the program's exit status. A program killed by a signal has
`__signal` set and `__exitcode` 127; one that could not be started has
`__exitcode` 127 and a message on stderr, like a shell. These are rules of
the [backend contract](../DESIGN.md#4-backend-contract): the posix backend
learns of a start failure from its status pipe ([`reap`][reap]), luv from
`uv.spawn` returning nothing ([`run`][luv_run]), and popen cannot tell it
from an exit status of 127. Under popen a killed program shows as `128 + N`
with `__signal` 0, and its merged strategies on Lua 5.1 and LuaJIT see no
exit status at all, which `sh.capabilities().exitcode` reports
([section 5](../DESIGN.md#5-capabilities)).

## Errors

With `raise_errors` on, the default, [`execute`][execute] asks
[`failure`][failure] for a message after each run
([section 3.6](../DESIGN.md#36-errors)):

1. a run that exited 0 and was not killed has none;
2. when stderr holds text, the trimmed text is the message:
   `ls: /missing: No such file or directory`;
3. otherwise the rendered pipeline and how it ended:
   `sh -c 'exit 3': exit status 3` or `...: killed by signal 9`.

[`runner`][runner] raises it with level 2, so the position in front of the
message is the line that called the command. The builtins never raise;
[`fail`][fail] puts the message in `__stderr` and 1 in `__exitcode`. With
`raise_errors` off every Result comes back, and the script checks
`__exitcode`.

## Verbose, trace and the sink

[`pipe.run`][pipe_run] owns the output plumbing
([section 3.7](../DESIGN.md#37-verbose-and-trace)). With `verbose` set it
passes two callbacks to the backend, built by [`writer`][writer]: each chunk
of stdout goes to `io.stdout` and each chunk of stderr to `io.stderr`,
written as it arrives and flushed, byte for byte, so that a progress bar
which redraws with `\r` animates. With `trace` set, [`trace`][trace]
writes `+ <pipeline>` to stderr before the run; in a chain the line grows
with every stage. A `sink` function replaces both io writes and receives
the stream name (`"stdout"`, `"stderr"` or `"trace"`) and the chunk. The
Result holds the whole output in any case; streaming never consumes it.

Chunk sizes depend on the backend ([pipes](pipes.md)); under popen, stderr
arrives in one piece after the program has exited.

[make_result]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L136
[result_tostring]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L99
[result_concat]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L117
[result_index]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L123
[reap]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L254
[luv_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L216
[execute]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L196
[failure]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L181
[runner]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L212
[fail]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L277
[pipe_run]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L63
[writer]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L25
[trace]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L36
