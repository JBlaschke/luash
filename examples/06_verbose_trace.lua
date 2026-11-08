-- Watch commands run: trace prints each pipeline, verbose streams output.
local sh = require("sh")

-- "+ <pipeline>" goes to stderr before each stage runs, like `set -x`.
sh.config.trace = true
sh.seq(1, 3):wc("-l")
-- + seq 1 3
-- + seq 1 3 | wc -l

-- Verbose copies the output to stdout and stderr while the program runs,
-- byte for byte: progress bars that redraw a line with \r animate.
sh.config.verbose = true
sh.sh("-c", "echo out; echo err >&2")

-- A sink takes over from the io writes. It gets the stream name, which
-- is "stdout", "stderr" or "trace", and the chunk.
local log = {}
sh.config.sink = function(stream, chunk)
    log[#log + 1] = stream .. ": " .. chunk
end
sh.echo("a", "b")
sh.config.verbose = false
sh.config.trace   = false
sh.config.sink    = nil
io.write(table.concat(log))
-- trace: + echo a b
-- stdout: a b
