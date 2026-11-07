-- Process backend on luv, the libuv binding for Lua (handoff/DESIGN.md
-- sections 4 and 6.2). uv.spawn starts the program with three pipes, and
-- run() drives the libuv loop with uv.run("once") until the child has exited
-- and both of its output pipes have reached EOF. libuv writes the input
-- while it reads the output, so no input size can deadlock.
--
-- run() must not be called from inside a libuv callback: the loop is not
-- re-entrant, and sh is a synchronous API. run() raises an error when it
-- detects that case. Handles that the host owns on the same loop are
-- serviced while run() waits, but run() never waits for them, and the
-- pipes and the process handle that run() creates are closed before it
-- returns.
--
-- luv is loaded with pcall, so this module also loads on an interpreter
-- without it; available() then returns false and the reason.
local M = { name = "luv" }

local ok, uv = pcall(require, "luv")

-- require's message names the problem on its first line and, when the C
-- library failed to load, the cause on the second; the rest lists every
-- path that was searched. Keep the first two lines, joined.
local load_error = nil
if not ok then
    load_error = (tostring(uv):gsub("\n\t", " ", 1)):match("^[^\n]*")
end

-- Closes a handle unless it is closed or closing already (luv raises on a
-- second close).
local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
end

local function ignore()
end

local function check_argv(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("sh.backend.luv.run: argv must be a non-empty array", 3)
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            error("sh.backend.luv.run: argv[" .. i .. "] is not a string", 3)
        end
    end
end

-- libuv does not ignore SIGPIPE: measured with luv 1.53 on macOS, a write
-- to a child that has already exited (head -c 1 given 1 MB of input) kills
-- the host with status 141 before the write callback can report EPIPE. A
-- libuv signal handle for SIGPIPE replaces the default action, and the
-- write then fails with EPIPE. libuv can neither report nor restore the
-- previous disposition (closing the handle resets it to SIG_DFL, which
-- would undo a host's SIG_IGN), so the handle is created by the first run
-- with input and kept, unreferenced, for the life of the process, much as
-- Node.js ignores SIGPIPE for good. Where SIGPIPE does not exist (Windows)
-- start() fails and nothing is installed.
local sigpipe_handle = nil  -- nil: not tried yet; false: not available

local function catch_sigpipe()
    if sigpipe_handle ~= nil then return end
    sigpipe_handle = false
    local handle = uv.new_signal()
    if not handle then return end
    local called, started = pcall(handle.start, handle, "sigpipe", ignore)
    if called and started then
        handle:unref()
        sigpipe_handle = handle
    else
        close(handle)
    end
end

-- Writes `input` to the child's stdin, then shuts the pipe down and closes
-- it, so the child sees EOF. A failed write means that the child closed its
-- stdin early (EPIPE): the pipe is closed and the rest of the input dropped.
local function feed(pipe, input)
    if input == "" then
        close(pipe)
        return
    end
    local function after_write(err)
        if err or pipe:is_closing() then
            close(pipe)
        elseif not pipe:shutdown(function() close(pipe) end) then
            close(pipe)
        end
    end
    if not pipe:write(input, after_write) then close(pipe) end
end

-- Reads `pipe` into `chunks` and passes each chunk to `deliver`. At EOF, or
-- on a read error, closes the pipe and calls `done()`.
local function drain(pipe, chunks, deliver, done)
    pipe:read_start(function(_, chunk)
        if chunk then
            chunks[#chunks + 1] = chunk
            deliver(chunk)
        else
            close(pipe)
            done()
        end
    end)
end

---Reports whether luv can be loaded on this interpreter.
---@return boolean available
---@return string|nil reason  why luv cannot be loaded
function M.available()
    if ok then return true end
    return false, load_error
end

---Describes what this backend can do (handoff/DESIGN.md section 5).
---@return table capabilities
function M.capabilities()
    return {
        name            = "luv",
        strategy        = nil,
        stdin           = true,
        separate_stderr = true,
        streaming       = true,
        exitcode        = true,
        signals         = true,
    }
end

---Accepts the options of the popen backend and ignores them.
---@param _ table|nil
function M.configure(_)
end

---Runs argv[1], found on PATH, with the remaining elements as arguments.
---A child that cannot start, fails or is killed is reported in the
---result, never raised. run() raises for a malformed call, when called
---from inside a libuv callback, and with the error of an on_stdout or
---on_stderr callback: that stops the child, and the error is raised once
---every handle is closed, because luv would otherwise end the process.
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  written to the child's stdin, then EOF
---@param opts table|nil  fields on_stdout(chunk), on_stderr(chunk), cwd
---@return table result  fields exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    if not ok then
        error("sh.backend.luv.run: luv cannot be loaded: " .. load_error, 2)
    end
    input = input or ""
    opts  = opts or {}
    if opts.cwd ~= nil and type(opts.cwd) ~= "string" then
        error("sh.backend.luv.run: opts.cwd must be a string", 2)
    end
    if uv.loop_mode and uv.loop_mode() then
        error("sh.backend.luv.run: called from inside a libuv callback", 2)
    end

    local stdin_pipe  = uv.new_pipe(false)
    local stdout_pipe = uv.new_pipe(false)
    local stderr_pipe = uv.new_pipe(false)
    local out_chunks  = {}
    local err_chunks  = {}
    local pending     = 3  -- process exit, stdout EOF, stderr EOF
    local exit_code, exit_signal

    local function done()
        pending = pending - 1
    end

    local function on_exit(code, signal)
        exit_code   = code
        exit_signal = signal
        done()
    end

    local args = {}
    for i = 2, #argv do
        args[i - 1] = argv[i]
    end
    local options = {
        args  = args,
        stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
        cwd   = opts.cwd,
    }
    local process, spawn_error = uv.spawn(argv[1], options, on_exit)

    if not process then
        close(stdin_pipe)
        close(stdout_pipe)
        close(stderr_pipe)
        uv.run("nowait")  -- finish the closes, and luv's close of the process
        return {
            exitcode = 127, signal = 0, stdout = "",
            stderr   = argv[1] .. ": " .. tostring(spawn_error) .. "\n",
            cause    = "failed",
        }
    end

    -- The first error raised by a callback, raised again after cleanup.
    local failed, failure = false, nil

    local function abort(err)
        if not failed then
            failed  = true
            failure = err
        end
        if exit_code == nil then process:kill("sigkill") end
    end

    local function deliver_to(callback)
        return function(chunk)
            if callback and not failed then
                local called, err = pcall(callback, chunk)
                if not called then abort(err) end
            end
        end
    end

    if input ~= "" then catch_sigpipe() end
    feed(stdin_pipe, input)
    drain(stdout_pipe, out_chunks, deliver_to(opts.on_stdout), done)
    drain(stderr_pipe, err_chunks, deliver_to(opts.on_stderr), done)

    while pending > 0 do
        local alive, loop_error = uv.run("once")
        if not alive and pending > 0 then
            -- Nothing is left that could finish the run: stop, do not spin.
            loop_error = loop_error or "no active handles"
            abort("sh.backend.luv.run: libuv loop stopped: " .. loop_error)
            break
        end
    end

    -- Closing stdin cancels a write that the child never read, for example
    -- when a background grandchild keeps the pipe open.
    close(process)
    close(stdin_pipe)
    close(stdout_pipe)
    close(stderr_pipe)
    uv.run("nowait")  -- run the close callbacks so the loop can go idle

    if failed then error(failure, 0) end

    local result = {
        exitcode = exit_code, signal = 0,
        stdout   = table.concat(out_chunks),
        stderr   = table.concat(err_chunks),
        cause    = "exited",
    }
    if exit_signal and exit_signal > 0 then
        result.exitcode = 127
        result.signal   = exit_signal
        result.cause    = "killed"
    end
    return result
end

return M
