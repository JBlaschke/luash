# Streaming: pump and writer

Two pieces of code carry a program's bytes. The **pump** is the loop in
the backend that moves them while the program runs: the input into its
stdin, its stdout and stderr out, in chunks, as the program reads and
writes. The **writer** is the run path's end of it: with `verbose` set,
[`pipe.run`][pipe_run] gives the backend one callback per output stream,
and the pump hands every chunk to it the moment it was read. The pump
runs at every command; the writer only in verbose mode. Design:
[section 3.7](../DESIGN.md#37-verbose-and-trace) and
[section 6](../DESIGN.md#6-backend-designs).

## The pump

The [backend contract](../DESIGN.md#4-backend-contract) fixes what a
pump does. `run(argv, input, opts)` writes all of `input` to the
program's stdin and then closes it, so that the program sees EOF; it
reads stdout and stderr to their end; it returns, with the exit status,
once the program has exited and both outputs are at EOF. While it runs,
each chunk goes to `opts.on_stdout` or `opts.on_stderr` when the caller
gave one, and the chunks of a stream concatenate to the `stdout` or
`stderr` of the result, byte for byte. The three backends keep that
contract in three ways.

### posix: a poll loop

[`pump`][pump] in the posix backend is the mechanism in its plainest
form. [`spawn`][spawn] has forked the program with a pipe on each of its
three standard descriptors, and the parent holds the write end of stdin
and the read ends of stdout and stderr. The pump puts the three in a
`poll` set, stdin watched for room and the outputs for data (with no
input, stdin is closed before the loop starts), and each round asks
[`posix.poll`][poll], with no timeout, which of them are ready:

- [`feed`][feed] writes the next slice of the input to stdin, which is
  non-blocking: at most 64 KiB (`WRITE_SIZE`), as much as the kernel
  takes, and advances a position in the input string. Once the position
  passes the end, it closes stdin and drops it from the set; that close
  is the EOF the program waits for. A write that reports `EAGAIN` or
  `EINTR` wrote nothing and waits for the next round. Any other error,
  `EPIPE` when the program closed its stdin or exited, closes stdin too,
  and the rest of the input is dropped.
- [`drain`][drain] reads up to 4 KiB (`READ_SIZE`) from an output,
  appends the chunk to the list kept for that stream and passes it to
  the callback. An empty read is EOF: the descriptor is closed and
  dropped.

The loop ends when the set is empty. [`run`][posix_run] then calls
[`reap`][reap], which waits for the exit status, and concatenates the two
lists into the result.

One loop over all three descriptors is what makes any input size safe. A
pipe buffers tens of kilobytes (64 KiB on Linux), and a program that
writes reads no further once its stdout pipe is full. A parent that wrote
the whole input before reading anything would block as soon as the
program stopped reading, while the program blocked on its full output:
`cat` with a 64 KiB input hung the 1.x backend that way
([section 6.1](../DESIGN.md#61-posix-shbackendposixlua)). The pump
writes a slice only when the kernel has room and reads whenever output
is there, so neither side waits on the other.

`SIGPIPE` is ignored while the loop runs: a write to a program that has
exited then fails with `EPIPE` instead of killing the host, which is how
`sh.head({ __input = big }, "-c", "1")` returns one byte of a 1 MiB
input. The loop runs under `pcall`, so an error raised by a callback
still closes the pipes, reaps the program and restores the signal before
it is raised again from the command call.

### luv: libuv pumps

The luv backend has no loop of its own over the descriptors; libuv does
the pumping, and [`run`][luv_run] turns its event loop. [`feed`][luv_feed]
gives the whole input to one `pipe:write`, with a callback that shuts
the pipe down for EOF once the input has gone out, or closes it when the
write failed because the program went away. [`drain`][luv_drain] starts
reading an output with `read_start`; its callback appends each chunk and
delivers it. [`uv.run("once")`][uv_run_once] runs one round of the loop
at a time, until three events have come: the process exited, stdout
reached EOF, stderr reached EOF. libuv interleaves the writes and the
reads, so no input size can deadlock here either.

A chunk is whatever libuv read at once, up to 64 KiB: `seq 1 3000`
arrives as one chunk of 13893 bytes where posix delivers four. The
callbacks run inside libuv's read callbacks, which has two consequences.
[`deliver_to`][deliver_to] wraps each call in `pcall`, since an error
that escapes a libuv callback ends the process: the error is recorded,
[`abort`][abort] kills the program and stops reading, and the error is
raised again once every handle is closed. And a callback cannot start
another command: the loop is not re-entrant, and `run`
[refuses][loop_mode] with `called from inside a libuv callback`.

### popen: a read loop over one pipe

`io.popen` gives the popen backend one pipe, the program's stdout.
[`execute`][popen_execute] reads it with `h:read(4096)` until EOF,
appending each block and passing it to `on_stdout`. stdio's `fread`
fills a block before it returns, so a chunk is 4 KiB until the last one,
and a short line waits in the block until more output or the program's
exit completes it: `echo a; sleep 1; echo b` reaches the sink as `a` and
then `b` under posix and luv, and as one chunk `a\nb\n` a second later
under popen. The input is not pumped: the file strategies write it to a
temp file before the shell starts, and the shell redirects stdin from
that file. stderr goes to a second temp file, which
[`run_with_files`][run_with_files] reads after `h:close()` and passes to
`on_stderr` in one piece, after the program has exited. Under the merged
strategies stderr is `2>&1` and arrives inside the stdout chunks
([pipes](pipes.md#popen-one-pipe-and-a-shell-string)).

| Backend | stdin | stdout and stderr chunks |
|---|---|---|
| posix | 64 KiB slices, written as the program reads | up to 4 KiB each, as soon as data is there |
| luv | one write, paced by libuv | up to 64 KiB each, as soon as data is there |
| popen, file strategies | a temp file, written before the start | stdout in 4 KiB blocks, each once full or at EOF; stderr in one piece after exit |
| popen, merged strategies | the command line (`basic`) or `/dev/null` (`minimal`) | both together, in 4 KiB blocks |

## The writer

[`pipe.run`][pipe_run] is the one caller of a backend's `run`, and it
passes callbacks only when `verbose` is set. [`writer`][writer] builds
one per stream from the configuration. Without a sink, the callback
writes the chunk to the stream's io handle, `io.stdout` or `io.stderr`,
and flushes: nothing is added, nothing removed, and the flush after each
chunk is what makes a progress bar that redraws with `\r` animate in the
terminal instead of appearing once at the end. With a sink, the callback
is `sink(stream, chunk)` with the stream's name. [`trace`][trace] writes
the `+ <pipeline>` line the same way, to `io.stderr` or as
`sink("trace", line)`, just before the backend starts the program.

The writer only forwards. The backend keeps every chunk, and
[`execute`][execute] builds the Result from the concatenation, so
`__stdout` and the verbose output are the same bytes, and a sink can
collect, prefix or filter without touching the Result
([results](results.md#verbose-trace-and-the-sink)). Without `verbose`
the `opts` table is empty: the pump runs just the same, and the chunks
only accumulate.

A sink runs in the middle of the pump, so what it does there matters.
An error it raises comes out of the command call as that error, and no
Result is returned: posix closes the pipes and waits for the program,
which ends at its next write to them or on its own; luv kills it; popen
closes the handle and waits. A sink that starts a command of its own
works under posix and popen, where the nested run is a complete inner
pump, and raises under luv, as above. Such a sink must also guard
against itself: the nested command's output arrives at the same sink.

## Pipelined commands

A chain, or a [`Pipeline`][pipeline_run], runs its stages one after
another ([pipes](pipes.md#between-stages-a-string-handoff)). The
[`runner`][runner] takes the Result of the stage before, and its whole
`__input` becomes the `input` that the next stage's pump writes: in
64 KiB slices under posix, one libuv write under luv, a temp file under
popen. The stages are connected by a string, never by a pipe, so a stage
starts once the one before has exited and all of its output has been
collected.

Every stage goes through `pipe.run`, with a trace line and writer
callbacks of its own. So in verbose mode the output of every stage
streams, not only that of the last one, and the trace line grows by a
stage each time:

```lua
sh.config.verbose = true
sh.config.trace   = true
sh.seq(1, 3):cat():wc("-l")
```

```
+ seq 1 3
1
2
3
+ seq 1 3 | cat
1
2
3
+ seq 1 3 | cat | wc -l
       3
```

A stage that fails with `raise_errors` on has streamed its output by the
time the error is raised: the pump ran to the end before
[`failure`][failure] looked at the exit status. The builtins (`cd`,
`pushd`, `popd`, `pushenv`, `popenv`, `print`) start no program and run
no pump, so a chain through one of them shows neither a trace line nor
output for that stage.

## How to

### Tell the stages apart in verbose output

Each trace line names the stage whose chunks follow. A sink can keep the
last stage and prefix every line with it; the lines are assembled from
the chunks, because a chunk can end in the middle of one:

```lua
local stage = ""
local rest  = { stdout = "", stderr = "" }
sh.config.verbose = true
sh.config.trace   = true
sh.config.sink    = function(stream, chunk)
    if stream == "trace" then
        stage = chunk:match("([^|\n]+)%s*$"):gsub("^[%+%s]+", "")
        return
    end
    local text = rest[stream] .. chunk            -- a chunk may end mid-line
    for line in text:gmatch("[^\n]*\n") do
        io.write("[", stage, "] ", line)
    end
    rest[stream] = text:match("[^\n]*$")
end
sh.seq(1, 3):cat():wc("-l")
```

```
[seq 1 3] 1
[seq 1 3] 2
[seq 1 3] 3
[cat] 1
[cat] 2
[cat] 3
[wc -l]        3
```

A last line without a newline stays in `rest`.

### Stream one stage only

`verbose` is read at each run, so it can be set around the one stage
that should show
([configuration](configuration.md#change-a-setting-for-one-call)):

```lua
local sorted = sh.seq(1, 100000):sort("-n")   -- quiet
sh.config.verbose = true
sorted:tail("-n", 3)                           -- only this stage streams
sh.config.verbose = false
```

### Run a command from a sink

Under posix and popen a sink may run a command, which is a complete
inner pump; the sink receives that command's output too, so it guards
against re-entry:

```lua
local inside = false
sh.config.verbose = true
sh.config.sink    = function(stream, chunk)
    io.write(chunk)
    if stream == "stderr" and not inside then
        inside = true
        sh.logger("-t", "build", chunk)        -- a nested run
        inside = false
    end
end
```

Under luv the nested call raises `called from inside a libuv callback`;
a sink there collects the chunks and acts once the command has returned.

### Stop a run from a sink

An error raised in the sink ends the run: it comes out of the command
call, and the program is reaped (posix and popen wait for it to exit,
which it does at its next write; luv kills it):

```lua
sh.config.verbose = true
sh.config.sink    = function(stream, chunk)
    if chunk:find("FATAL", 1, true) then error("build aborted", 0) end
    io.write(chunk)
end
local ok, err = pcall(sh.make, "-j4")          -- err: "build aborted"
```

No Result comes back from a run stopped this way; the chunks the sink
saw before the error are all it keeps.

[pipe_run]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L63
[writer]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L25
[trace]: https://github.com/JBlaschke/luash/blob/main/sh/pipe.lua#L36
[pump]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L197
[spawn]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L147
[poll]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L240
[feed]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L207
[drain]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L218
[posix_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L375
[reap]: https://github.com/JBlaschke/luash/blob/main/sh/backend/posix.lua#L261
[luv_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L266
[luv_feed]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L138
[luv_drain]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L155
[uv_run_once]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L360
[deliver_to]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L345
[abort]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L335
[loop_mode]: https://github.com/JBlaschke/luash/blob/main/sh/backend/luv.lua#L271
[popen_execute]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L790
[run_with_files]: https://github.com/JBlaschke/luash/blob/main/sh/backend/popen.lua#L841
[execute]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L196
[runner]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L212
[failure]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L181
[pipeline_run]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L658
