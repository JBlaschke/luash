---
--- Process I/O backend using luv (libuv bindings for Lua).
---
--- Backend: luv (require "luv")
--- Provides full stdin/stdout/stderr separation with no temp files.
---
--- Event-loop note: pipe_simple() drives the default loop with
--- uv.run("once") until *its own* handles have completed, so it coexists
--- with other handles owned by the host application.  It must NOT be
--- called from inside a libuv callback, however: the loop is not
--- reentrant.  In that situation a genuinely asynchronous variant is
--- required (not currently provided).
---

local uv = require("luv")

local M = {}

M.name = "luv"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Drain a readable pipe into a table of chunks; call on_done() exactly
--- once, on EOF or read error.
local function read_pipe_into(pipe, dest, verbose, on_done)
    pipe:read_start(function(err, data)
        if err or data == nil then
            -- read error or EOF
            pipe:read_stop()
            if not pipe:is_closing() then pipe:close() end
            on_done()
        else
            dest[#dest + 1] = data
            if verbose then io.write(data) end
        end
    end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Spawn `cmd` with `args`, feed `input` on stdin, wait for completion.
--- Returns: exit_status, wait_cause, stdout_string, stderr_string
---
--- @param input   string   Data to write to the child's stdin.
--- @param cmd     string   Program name (resolved via PATH by libuv).
--- @param args    table    Array of string arguments.
--- @param verbose boolean  If true, write stdout/stderr chunks to io.write.
function M.pipe_simple(input, cmd, args, verbose)
    local stdin_pipe  = uv.new_pipe()
    local stdout_pipe = uv.new_pipe()
    local stderr_pipe = uv.new_pipe()

    local stdout_chunks, stderr_chunks = {}, {}
    local exit_code, exit_signal

    -- Completion accounting: process exit + stdout EOF + stderr EOF.
    local pending = 3
    local function done() pending = pending - 1 end

    -- IMPORTANT: declare `handle` *before* the spawn so the on-exit
    -- closure captures this local.  In `local h = uv.spawn(..., cb)` the
    -- local's scope starts after the statement, so cb would silently
    -- reference the global `handle` (nil) instead.
    local handle, pid_or_err

    handle, pid_or_err = uv.spawn(cmd, {
        args  = args,
        stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    }, function(code, signal)
        exit_code, exit_signal = code, signal
        if handle and not handle:is_closing() then handle:close() end
        done()
    end)

    if not handle then
        stdin_pipe:close()
        stdout_pipe:close()
        stderr_pipe:close()
        error("pipe_luv: spawn failed for '" .. cmd .. "': " .. tostring(pid_or_err))
    end

    -- Queue the input, then half-close stdin so the child sees EOF.
    -- libuv buffers the write internally, so a large input cannot
    -- deadlock against unread child output (unlike a blocking write
    -- into a fixed-size kernel pipe).
    local function close_stdin()
        if not stdin_pipe:is_closing() then
            stdin_pipe:shutdown(function()
                if not stdin_pipe:is_closing() then stdin_pipe:close() end
            end)
        end
    end

    if input and #input > 0 then
        stdin_pipe:write(input, close_stdin)
    else
        close_stdin()
    end

    read_pipe_into(stdout_pipe, stdout_chunks, verbose, done)
    read_pipe_into(stderr_pipe, stderr_chunks, verbose, done)

    -- Pump the loop one iteration at a time until *our* work is finished.
    -- Other handles on the default loop are serviced but not waited for.
    while pending > 0 do
        uv.run("once")
    end
    -- Let any still-queued close callbacks fire without blocking.
    uv.run("nowait")

    local cause = (exit_signal and exit_signal > 0) and "killed" or "exited"
    return exit_code or 127, cause,
        table.concat(stdout_chunks), table.concat(stderr_chunks)
end

return M
