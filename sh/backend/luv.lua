-- Process backend on luv, the libuv binding for Lua (handoff/DESIGN.md
-- sections 4 and 6.2). uv.spawn starts the program with three pipes, and
-- run() drives the libuv loop with uv.run("once") until the child has exited
-- and both of its output pipes have reached EOF. libuv writes the input
-- while it reads the output, so no input size can deadlock.
--
-- A child that cannot start, fails or is killed is reported in the result
-- of run(), never raised. run() raises for a malformed call, when luv
-- cannot be loaded, when it is called from inside a libuv callback, when
-- the loop stops before the child has finished (an internal error), and
-- with the error of an on_stdout or on_stderr callback. luv ends the
-- process on an error in its callback, so a callback's error is caught,
-- stops the child, and is raised again once every handle is closed.
--
-- run() must not be called from inside a libuv callback: the loop is not
-- re-entrant, and sh is a synchronous API. Handles that the host owns on
-- the same loop are serviced while run() waits, but run() never waits for
-- them, and the pipes and the process handle that run() creates are closed
-- before it returns.
--
-- chdir() and getcwd() are uv.chdir and uv.cwd: `cd` changes the directory
-- of the process.
--
-- luv is loaded with pcall, so this module also loads on an interpreter
-- without it; available() then returns false and the reason.
local M = { name = "luv" }

local ok, uv = pcall(require, "luv")

-- require's message names the problem on its first line. When the C library
-- exists but failed to load, the second line holds the cause; otherwise the
-- following lines list every path that was searched.
local load_error = nil
if not ok then
    local message = tostring(uv)
    if message:find("^error loading module") then
        message = message:gsub("\n\t", " ", 1)
    end
    load_error = message:match("^[^\n]*"):gsub(":$", "")
end

-- Closes a handle unless it is closed or closing already (luv raises on a
-- second close).
local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
end

local function ignore()
end

local function callable(value)
    if type(value) == "function" then return true end
    local mt = getmetatable(value)
    return type(mt) == "table" and mt.__call ~= nil
end

-- Raises, at the caller of run(), for a malformed call, before any handle
-- exists. libuv hands strings to the OS as C strings, so a NUL byte would
-- cut a program name, an argument or the directory short without notice.
local function check_call(argv, input, opts)
    local function fail(message)
        error("sh.backend.luv.run: " .. message, 4)
    end
    if type(argv) ~= "table" or #argv == 0 then
        fail("argv must be a non-empty array")
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            fail("argv[" .. i .. "] is not a string")
        elseif argv[i]:find("\0", 1, true) then
            fail("argv[" .. i .. "] contains a NUL byte")
        end
    end
    if input ~= nil and type(input) ~= "string" then
        fail("input must be a string")
    end
    if opts == nil then return end
    if type(opts) ~= "table" then
        fail("opts must be a table")
    end
    local cwd = opts.cwd
    if cwd ~= nil and (type(cwd) ~= "string" or cwd:find("\0", 1, true)) then
        fail("opts.cwd must be a string without NUL bytes")
    end
    for _, key in ipairs({ "on_stdout", "on_stderr" }) do
        if opts[key] ~= nil and not callable(opts[key]) then
            fail("opts." .. key .. " must be a function")
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
-- Node.js ignores SIGPIPE for good. Each later run with input re-arms it:
-- other code may have reset SIGPIPE in the meantime (a luaposix save and
-- restore turns libuv's handler into SIG_DFL), and start() alone does
-- nothing for a signal the handle already watches. A handle that the host
-- closed is replaced. Where SIGPIPE does not exist (Windows) start() fails
-- and nothing is installed.
local sigpipe_handle = nil  -- nil: none yet; false: SIGPIPE not available

local function catch_sigpipe()
    if sigpipe_handle == false then return end
    if sigpipe_handle and not sigpipe_handle:is_closing() then
        sigpipe_handle:stop()
        if sigpipe_handle:start("sigpipe", ignore) then return end
        close(sigpipe_handle)
    end
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

-- Reads `pipe` into `chunks` and passes each chunk to `deliver`; calls
-- `finish()` at EOF or on a read error.
local function drain(pipe, chunks, deliver, finish)
    pipe:read_start(function(_, chunk)
        if chunk then
            chunks[#chunks + 1] = chunk
            deliver(chunk)
        else
            finish()
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

---Changes the working directory of the process.
---@param dir string
---@return true|nil ok
---@return string|nil err  "<dir>: ENOENT: no such file or directory"
function M.chdir(dir)
    if not ok then
        local msg = "sh.backend.luv.chdir: luv cannot be loaded: "
        error(msg .. load_error, 2)
    end
    local done, err = uv.chdir(dir)
    if done then return true end
    return nil, dir .. ": " .. tostring(err)
end

---The working directory of the process.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    if not ok then
        local msg = "sh.backend.luv.getcwd: luv cannot be loaded: "
        error(msg .. load_error, 2)
    end
    return uv.cwd()
end

---Runs argv[1], found on PATH, with the rest as its arguments (the module
---comment at the top says when it raises).
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  written to the child's stdin, then EOF
---@param opts table|nil  fields on_stdout(chunk), on_stderr(chunk), cwd
---@return table result  fields exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_call(argv, input, opts)
    if not ok then
        error("sh.backend.luv.run: luv cannot be loaded: " .. load_error, 2)
    end
    if uv.loop_mode and uv.loop_mode() then
        error("sh.backend.luv.run: called from inside a libuv callback", 2)
    end
    input = input or ""
    opts  = opts or {}

    local stdin_pipe  = uv.new_pipe(false)
    local stdout_pipe = uv.new_pipe(false)
    local stderr_pipe = uv.new_pipe(false)
    local out_chunks  = {}
    local err_chunks  = {}
    local pending     = 3  -- process exit, stdout EOF, stderr EOF
    local exit_code, exit_signal

    local function on_exit(code, signal)
        exit_code   = code
        exit_signal = signal
        pending     = pending - 1
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

    -- Returns a function that closes an output pipe and counts it as
    -- finished, once: at its EOF, or earlier when the run is aborted.
    local function finisher(pipe)
        local finished = false
        return function()
            if finished then return end
            finished = true
            close(pipe)
            pending = pending - 1
        end
    end
    local finish_out = finisher(stdout_pipe)
    local finish_err = finisher(stderr_pipe)

    -- The first error raised by a callback, raised again after cleanup.
    local failed  = false
    local failure = nil

    -- Records the first error, kills the child and stops reading, so that
    -- only the child's exit is waited for: a grandchild that holds an output
    -- pipe open cannot keep the run going (it gets SIGPIPE instead).
    local function abort(err)
        if not failed then
            failed  = true
            failure = err
        end
        if exit_code == nil then process:kill("sigkill") end
        finish_out()
        finish_err()
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
    drain(stdout_pipe, out_chunks, deliver_to(opts.on_stdout), finish_out)
    drain(stderr_pipe, err_chunks, deliver_to(opts.on_stderr), finish_err)

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
