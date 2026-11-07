---
--- Low-level process I/O via luaposix: fork/exec, async reads, and the
--- synchronous pipe_simple() helper that most callers use.
---
--- Backend: luaposix (require "posix")
--- Provides full stdin/stdout/stderr separation with no temp files.
---
local posix = require("posix")

local M = {}

--- Fork a child process with pipes wired to its stdin, stdout, and stderr.
--- Returns: pid, stdin_write_fd, stdout_read_fd, stderr_read_fd
local function popen3(path, ...)
    local r1, w1 = posix.pipe()
    local r2, w2 = posix.pipe()
    local r3, w3 = posix.pipe()
    assert(r1 and r2 and r3, "pipe() failed")

    local pid = posix.fork()
    assert(pid ~= nil, "fork() failed")

    if pid == 0 then
        -- Child: wire pipes to std fds, then exec.
        posix.close(w1)
        posix.close(r2)
        posix.close(r3)
        posix.dup2(r1, posix.fileno(io.stdin))
        posix.dup2(w2, posix.fileno(io.stdout))
        posix.dup2(w3, posix.fileno(io.stderr))
        posix.close(r1)
        posix.close(w2)
        posix.close(w3)

        local ret = posix.execp(path, ...)
        assert(ret ~= nil, "execp() failed")
        posix._exit(1)
        return
    end

    -- Parent: close the child-side ends.
    posix.close(r1)
    posix.close(w2)
    posix.close(w3)

    return pid, w1, r2, r3
end

--- Coroutine body: yields chunks from a file descriptor until EOF or error.
--- Each yield produces: (poll_status, ended, data, raw_poll_code)
local function read_async(fd, bufsize, timeout)
    while true do
        local poll_code = { posix.rpoll(fd, timeout) }
        if poll_code[1] == 0 then
            coroutine.yield(0, nil, nil, poll_code)
        elseif poll_code[1] == 1 then
            local buf = posix.read(fd, bufsize)
            local ended = (buf == nil or #buf == 0)
            coroutine.yield(1, ended, buf, poll_code)
            if ended then break end
        else
            coroutine.yield(nil, nil, nil, poll_code)
            break
        end
    end
end

--- Run `cmd` with the given args table, feeding `input` on stdin.
--- Returns: exit_status, wait_cause, stdout_string, stderr_string
---
--- @param input   string   Data to write to the child's stdin.
--- @param cmd     string   Program name (resolved via PATH).
--- @param args    table    Array of string arguments.
--- @param verbose boolean  If true, print stdout/stderr chunks as they arrive.
function M.pipe_simple(input, cmd, args, verbose)
    local pid, w, r, e = popen3(cmd, table.unpack(args))
    assert(pid ~= nil, "pipe_simple(): popen3() failed")

    posix.write(w, input)
    posix.close(w)

    local bufsize = 4096
    local timeout = 100

    local stdout, stderr = {}, {}
    local stdout_ended, stderr_ended = false, false
    local co_out = coroutine.create(function() read_async(r, bufsize, timeout) end)
    local co_err = coroutine.create(function() read_async(e, bufsize, timeout) end)

    while not (stdout_ended and stderr_ended) do
        if not stdout_ended then
            local _, pstatus, ended, buf = coroutine.resume(co_out)
            if pstatus == 1 then
                stdout_ended = ended
                if not ended then
                    stdout[#stdout + 1] = buf
                    if verbose then print(buf:sub(1, -2)) end
                end
            end
        end
        if not stderr_ended then
            local _, pstatus, ended, buf = coroutine.resume(co_err)
            if pstatus == 1 then
                stderr_ended = ended
                if not ended then
                    stderr[#stderr + 1] = buf
                    if verbose then print(buf:sub(1, -2)) end
                end
            end
        end
    end

    local _, wait_cause, wait_status = posix.wait(pid)
    posix.close(r)
    posix.close(e)

    return wait_status, wait_cause, table.concat(stdout), table.concat(stderr)
end

return M
