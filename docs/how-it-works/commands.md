# Commands as data

Every call goes through [`sh/command.lua`][command], which turns Lua values
into an argument vector and never starts a process. The rules are
[section 7](../DESIGN.md#7-argument-flattening-shcommandlua) of the design;
[`walk`][walk] and [`walk_table`][walk_table] implement them.

## Flattening

`walk` adds one value to the vector: a string as it is, a number through
`tostring`, `nil` and `false` as nothing, a table recursively. For a
table, `walk_table` takes the array entries first, then integer keys past a
hole in sorted order, then the string keys as flags sorted by byte, so that
the command line is the same on every run. [`format_flag`][format_flag]
writes `-k` for a one-letter key and `--key` otherwise, with `=value` for a
string or number and nothing for `false`. Keys starting with `_` are not
flags: `__input` is literal stdin, and a table with a string `__stdout` is
a Result, whose `__input` becomes stdin and whose `__pipeline` is recorded
as a source. A Command or Pipeline given as an argument is an error that
points at `:pipe()`, and a table that contains itself is caught.

[`parse`][parse] exposes the same flattening for the builtins, which also
need the Results' `__stdout`, `__stderr` and exit status to pass through.

## Command and Pipeline

[`Command(name, ...)`][Command] holds `name`, `args`, `stdin` and
`sources`. It is mutable: [`arg`][arg] appends more flattened arguments,
[`flag`][flag] appends one flag in call order (the way to control flag
order), [`input`][input] replaces the stdin, and [`copy`][copy] takes a
snapshot. [`argv`][argv] returns a new vector, the program first, which is
exactly what a backend receives.

A [`Pipeline`][Pipeline] is an array of Commands. [`Command:pipe`][cmd_pipe]
builds one, [`Pipeline:pipe`][pipe_pipe] appends in place, and on Lua 5.3
and newer the [`__bor`][bor] metamethod makes `a | b` a Pipeline too.
[`Pipeline:run`][pipeline_run] runs the stages left to right, feeding each
the Result of the one before, and returns the last Result.

Both types' `run()` call the runner that `sh/init.lua` installed with
[`set_runner`][set_runner], so `command.lua` is testable on its own.

## Rendering

`tostring` on a Command or Pipeline is [`render`][render], and it is what
error messages, trace lines and `__pipeline` show. Each word goes through
[`quote`][quote]: bare when it matches `^[%w%-%._/=:@%%+,]+$`, otherwise
single-quoted with `'` written as `'\''`. The sources of the first stage
render in front of it ([`render_feed`][render_feed]): one as `a | `,
several as the group `{ a; b; } | `. Later stages read the stage before
them, so their own sources are not shown, and literal stdin is never shown.
The rendering is for reading: the posix and luv backends pass the vector to
the program directly, without a shell, and popen quotes every word itself
([section 3.4](../DESIGN.md#34-command-and-pipeline)).

## Provenance

A Result's `__pipeline` is not the Command you ran but a snapshot.
[`provenance`][provenance] builds a new Command from the vector that the
backend got and pairs it with the source's Pipeline, so changing the
original afterwards does not rewrite history, and a chain `r = r:cat()`
does not keep every earlier input alive.

[command]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua
[walk]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L212
[walk_table]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L154
[format_flag]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L119
[parse]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L257
[Command]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L371
[arg]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L382
[flag]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L396
[input]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L412
[copy]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L438
[argv]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L448
[Pipeline]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L495
[cmd_pipe]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L503
[pipe_pipe]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L511
[bor]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L555
[pipeline_run]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L531
[set_runner]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L341
[render]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L326
[quote]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L270
[render_feed]: https://github.com/JBlaschke/luash/blob/main/sh/command.lua#L293
[provenance]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L163
