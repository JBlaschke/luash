do
local _ENV = _ENV
package.preload[ "sh.backend" ] = function( ... ) local arg = _G.arg;
---
--- sh.backend: the backend registry (DESIGN.md section 6.6).
---
--- A backend is a module sh/backend/<name>.lua that implements the contract
--- of DESIGN.md section 4: it runs programs and owns the working directory.
--- The registry selects one backend, configures it, and keeps it as the
--- backend in use until select() is called again; nothing about a backend
--- is probed at a run or a cd. sh/init.lua selects the default when it
--- loads, and sh.set_backend() selects another one. run, chdir, getcwd and
--- capabilities go to the backend in use: the frontend sees one interface.
---
--- A choice is a backend table of your own, a name ("posix", "luv",
--- "popen") or "auto": LUASH_BACKEND when set, otherwise the first backend
--- of ORDER[platform] that loads, is complete and is available. A backend is
--- configured with the options (popen's strategy and tmpdir, with
--- LUASH_POPEN_STRATEGY for a strategy of "auto") before it is asked
--- whether it is available, because popen answers for its configured
--- strategy. Both variables are read once, when this module loads.
---
--- sh.install() turns undefined globals into commands, and libraries read
--- optional globals to detect features. So a backend loads, is configured
--- and is asked whether it is available through sys.load_pcall, which keeps
--- undefined globals nil meanwhile, and install() first loads the
--- platform's backends with preload(). run, chdir and getcwd are called
--- directly: run() calls back into code that may use the commands.
---

local sys = require("sh.sys")

local M = {}

--- Backend preference by platform, see sys.platform().
M.ORDER = {
    posix   = { "posix", "luv", "popen" },
    windows = { "luv", "popen" },
    android = { "luv", "posix", "popen" },
}

--- The functions of the backend contract (DESIGN.md section 4); a module
--- that lacks one is not selected.
M.CONTRACT = {
    "available", "capabilities", "configure", "run", "chdir", "getcwd",
}

-- The value of an environment override; nil when unset, empty or "auto".
local function getenv(name)
    local value = os.getenv(name)
    if value == nil or value == "" or value == "auto" then return nil end
    return value
end

local ENV = {
    backend  = getenv("LUASH_BACKEND"),
    strategy = getenv("LUASH_POPEN_STRATEGY"),
}

-- The first line of an error value, without a trailing colon.
local function first_line(err)
    local line = tostring(err):match("^([^\n]*)")
    return (line:gsub(":%s*$", ""))
end

-- The options a backend is configured with: a copy of `opts` (popen's
-- strategy and tmpdir; a backend of your own may take more) in which
-- LUASH_POPEN_STRATEGY replaces a strategy of "auto".
local function configuration(opts)
    local merged = {}
    for key, value in pairs(opts or {}) do
        merged[key] = value
    end
    if merged.strategy == nil or merged.strategy == "auto" then
        merged.strategy = ENV.strategy or "auto"
    end
    return merged
end

-- The backend modules loaded so far, by name.
local loaded = {}

-- The backend in use and the options it was configured with; nil and the
-- reason while no selection has succeeded.
local active     = nil
local options    = configuration(nil)
local unselected = "none selected"

-- The names of the available backends, found by available() once per
-- selection.
local probed = nil

-- The platform's order of preference.
local function order()
    return M.ORDER[sys.platform()] or M.ORDER.posix
end

-- The module of backend `name`, or nil and the reason it does not load. A
-- failed load is tried again at the next selection, which finds a backend
-- installed in the meantime.
local function load(name)
    if loaded[name] then return loaded[name] end
    local ok, mod = sys.load_pcall(require, "sh.backend." .. name)
    if not ok then return nil, first_line(mod) end
    if type(mod) ~= "table" then
        return nil, "sh.backend." .. name .. " is not a table"
    end
    loaded[name] = mod
    return mod
end

-- What `mod` lacks of the contract, or nil when it implements it.
local function incomplete(mod)
    if type(mod) ~= "table" then return "is not a table" end
    if type(mod.name) ~= "string" then return "has no name" end
    for _, key in ipairs(M.CONTRACT) do
        if type(mod[key]) ~= "function" then
            return "has no " .. key .. "()"
        end
    end
    return nil
end

-- Configure `mod` with `opts`, then ask whether it is available: true, or
-- false and the reason. A configure() that raises (popen: an unknown
-- strategy) makes the backend unavailable for that reason.
local function ready(mod, opts)
    local configured, err = sys.load_pcall(mod.configure, opts)
    if not configured then return false, first_line(err) end
    local asked, avail, why = sys.load_pcall(mod.available)
    if asked and avail then return true end
    return false, first_line(why or avail or "not available")
end

-- The backend `name`, configured with `opts`, when it loads, is complete
-- and is available; otherwise nil and the reason.
local function candidate(name, opts)
    local mod, why = load(name)
    if not mod then return nil, why end
    local lacks = incomplete(mod)
    if lacks then return nil, "sh.backend." .. name .. " " .. lacks end
    local ok, reason = ready(mod, opts)
    if not ok then return nil, reason end
    return mod
end

local function unavailable(name, why)
    error("sh.backend: " .. name .. " is unavailable: " .. why, 0)
end

-- The first available backend of the platform, configured with `opts`.
local function first_available(opts)
    local platform = sys.platform()
    local tried    = {}
    for _, name in ipairs(order()) do
        local mod, why = candidate(name, opts)
        if mod then return mod end
        tried[#tried + 1] = name .. " (" .. why .. ")"
    end
    local msg = "sh.backend: no backend available on " .. platform .. ": "
    error(msg .. table.concat(tried, "; "), 0)
end

-- How a choice of each type resolves to a backend configured with `opts`;
-- raises when the backend is not available.
local RESOLVE = {}

-- A table of your own that implements the contract.
function RESOLVE.table(choice, opts)
    local lacks = incomplete(choice)
    if lacks then error("sh.backend: the backend table " .. lacks, 0) end
    local ok, why = ready(choice, opts)
    if not ok then unavailable(choice.name, why) end
    return choice
end

-- A name, or "auto": LUASH_BACKEND when set, else the platform's first
-- available backend.
function RESOLVE.string(choice, opts)
    if choice == "auto" then choice = ENV.backend or "auto" end
    if choice == "auto" then return first_available(opts) end
    local mod, why = candidate(choice, opts)
    if not mod then unavailable(choice, why) end
    return mod
end

RESOLVE["nil"] = function(_, opts)
    return RESOLVE.string("auto", opts)
end

local function resolve(choice, opts)
    local by_type = RESOLVE[type(choice)]
    if not by_type then
        local kind = type(choice)
        error("sh.backend: a backend is a name or a table, not a " .. kind, 0)
    end
    return by_type(choice, opts)
end

--- Select the backend in use and configure it. `choice` is "auto" (or
--- nil), a backend name or a backend table; `opts` holds the options
--- (popen: strategy and tmpdir). Returns the backend. Raises when it is
--- not available, and the backend in use then stays as it was.
---@param choice string|table|nil
---@param opts table|nil
---@return table backend
function M.select(choice, opts)
    local chosen  = configuration(opts)
    local ok, mod = pcall(resolve, choice, chosen)
    if not ok then
        if active then
            -- The attempt may have reconfigured the backend in use (popen
            -- with another strategy): configure it again as it was.
            sys.load_pcall(active.configure, options)
        else
            unselected = mod
        end
        error(mod, 0)
    end
    active  = mod
    options = chosen
    probed  = nil
    return mod
end

--- The backend in use. Raises when none has been selected: no backend was
--- available when sh loaded, with the reason.
---@return table backend
function M.current()
    if active then return active end
    error("sh.backend: no backend in use: " .. unselected, 0)
end

--- The name of the backend in use.
---@return string
function M.name()
    return M.current().name
end

--- The capability table of the backend in use (DESIGN.md section 5).
---@return table
function M.capabilities()
    return M.current().capabilities()
end

--- Run `argv` with `input` on stdin through the backend in use (DESIGN.md
--- section 4 says what `opts` and the result hold).
---@param argv string[]
---@param input string
---@param opts table
---@return table result
function M.run(argv, input, opts)
    return M.current().run(argv, input, opts)
end

--- Change the working directory through the backend in use.
---@param dir string
---@return true|nil ok
---@return string|nil err
function M.chdir(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil, "sh.backend.chdir: expected a directory name"
    end
    return M.current().chdir(dir)
end

--- The working directory of the backend in use.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    return M.current().getcwd()
end

--- The names of the available backends, in the order of the platform:
--- those that load, are complete and are available with the options of
--- the backend in use. Found once per selection.
---@return string[]
function M.available()
    if probed then return probed end
    local names = {}
    for _, name in ipairs(order()) do
        local mod = loaded[name]
        local ok  = (mod ~= nil and mod == active)
            or candidate(name, options) ~= nil
        if ok then names[#names + 1] = name end
    end
    probed = names
    return names
end

--- Load the backends of this platform now, and with them the libraries
--- they need. sh.install() calls this before undefined globals become
--- commands, so that a script's own require("posix") after install() gets
--- the loaded module, as with the 1.x sh.lua, which loaded luaposix first.
function M.preload()
    for _, name in ipairs(order()) do
        load(name)
    end
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.backend.luv" ] = function( ... ) local arg = _G.arg;
-- Process backend on luv, the libuv binding for Lua (docs/DESIGN.md
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

---Describes what this backend can do (docs/DESIGN.md section 5).
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
end
end

do
local _ENV = _ENV
package.preload[ "sh.backend.popen" ] = function( ... ) local arg = _G.arg;
-- Process backend on io.popen, for interpreters that have neither
-- luaposix nor luv (docs/DESIGN.md sections 4, 5 and 6.3). Standard
-- library only; runs on Lua 5.1 to 5.5 and LuaJIT.
--
-- io.popen gives one pipe: the child's stdout. Strategies supply the rest,
-- from most to least capable:
--
--   shmem     stdin and stderr in temp files in a private directory under
--             /dev/shm (Linux tmpfs); separate stderr, exit status
--   standard  the same under the temp root: configure's tmpdir, else the
--             first writable of TMPDIR, TMP, TEMP and /tmp
--   basic     no temp files: the input goes on the command line as
--             `printf '%s' '<input>' |` and stderr is merged into stdout.
--             Every user of the machine can read that input in `ps`, and
--             the size limit for a command line caps it (128 KiB on
--             Linux, about 1 MiB on macOS). "auto" never picks basic while
--             a file strategy is available.
--   minimal   no temp files, no input (stdin is /dev/null), stderr merged
--
-- /bin/sh runs `exec <argv>` in a subshell, so argv[1] is always the
-- program found on PATH, never a shell builtin or function of that name,
-- and every argument reaches it verbatim (none can carry a NUL byte,
-- which raises). Every shell string first turns off the errexit, nounset
-- and xtrace options that bash as /bin/sh takes from an exported
-- SHELLOPTS, and removes exported bash functions named like the commands
-- it runs (cd, echo, printf, mkdir, rm and others). opts.cwd is entered
-- with `cd -P`, which resolves `..` like chdir() does. A program that
-- cannot be started (not found, not executable, a missing cwd) exits 127
-- with the shell's message on stderr, as from the other backends; a
-- program that exits 126 by itself shows as 127 too. A program name
-- starting with "-" and a command line longer than the system accepts are
-- start failures (cause "failed", exit code 127).
--
-- io.popen has no chdir, so `cd` is emulated: chdir() resolves the
-- directory through the shell (`cd -P ... && pwd -P`), which also checks
-- that it can be entered, and remembers it; run() enters it when opts.cwd
-- is nil, and getcwd() returns it. The emulated directory applies to the
-- programs this backend runs only, not to Lua's own io functions.
--
-- The private directory <root>/luash-<pid>-<random> is made once per
-- process and root with `mkdir -m 700`, which fails when the name exists,
-- so no other user can read it or plant a file or symlink in it. Lua
-- creates a marker file in it whose name, .luash-<32 hex digits from
-- /dev/urandom>, appears on no command line. A run starts only when the
-- marker is there, and reads and removes its files only when it still is:
-- a directory a temp cleaner removed is made again, and one that someone
-- else made under the same name since is never written to or read. Each
-- run writes in-<n> (input), err-<n> (stderr) and st-<n> (exit status)
-- there and removes them afterwards, also when the run raises. The shell
-- opens st-<n> before the program starts. cleanup_all() removes the
-- directory, and a finalizer calls it when the Lua state is closed.
-- os.exit(code) skips that unless its second argument is `true`
-- (honoured from Lua 5.2 and by LuaJIT 2.1, never by Lua 5.1), so a
-- script that ends with os.exit should call cleanup_all() first. A
-- directory left behind (luash-*) is safe to delete.
--
-- Exit status: the file strategies have the shell write it to st-<n>,
-- which works on every interpreter. The merged strategies take it from
-- h:close(), which reports it on Lua 5.2 and newer but not on Lua 5.1 or
-- LuaJIT, where exitcode is 0 and capabilities().exitcode is false. A
-- child killed by signal N shows as exit status 128 + N (signals = false).
--
-- Streaming: stdout reaches on_stdout in blocks of 4096 bytes (stdio's
-- fread fills a block before it returns); stderr reaches on_stderr in one
-- piece after the child has exited.
local M = { name = "popen" }

local ORDER     = { "shmem", "standard", "basic", "minimal" }
local MAX_TRIES = 10
local CHUNK     = 4096
local ARG_SLACK = 65536   -- shorter command lines skip the length check
local NOT_RUN   = 127     -- exit code of a program that was not started

local STRATEGIES = {
    shmem    = { files = true,  stdin = true  },
    standard = { files = true,  stdin = true  },
    basic    = { files = false, stdin = true  },
    minimal  = { files = false, stdin = false },
}

-- "cmd" on Windows (cmd.exe syntax, best effort), "sh" everywhere else
local MODE = package.config:sub(1, 1) == "\\" and "cmd" or "sh"

-- Lua 5.1 and LuaJIT only. rawget: after sh.install(), _G's __index makes
-- an undefined global a command function.
local newproxy = rawget(_G, "newproxy")

local config = { strategy = "auto", tmpdir = nil }

-- The directory chdir() moved to, nil until the first chdir(); run() enters
-- it when opts.cwd is nil (emulated `cd`, see the module comment).
local emulated = nil

local resolved     = nil   -- strategy name that config.strategy resolves to
local probed       = {}    -- root -> result of the writable check
local dirs         = {}    -- root -> { path, marker } in use under it
local made         = {}    -- every { path, marker } made, for cleanup_all
local counter      = 0     -- numbers the temp files of each run
local pid          = nil   -- id of a shell, from `echo $$`; false: none
local seeded       = false
local sentinel     = nil   -- userdata or table whose __gc calls cleanup_all
local popen_ok     = nil   -- io.popen works (cached once known)
local popen_why    = nil
local close_status = nil   -- h:close() reports the exit status
local cmd_limit    = nil   -- longest command line exec takes; false: unknown

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Every POSIX shell string starts here. bash as /bin/sh takes options from
-- an exported SHELLOPTS and functions from exported BASH_FUNC_<name>%%
-- variables. set turns off errexit, nounset and xtrace, with its own trace
-- sent nowhere, and unset removes functions of the names the string runs;
-- both are special builtins, which no function replaces.
local function sh_line(s, names)
    local line = "{ set +eux; } 2>/dev/null; "
    if names then
        line = line .. "unset -f " .. names .. "; "
    end
    return line .. s
end

-- A probe line for the platform's shell: cmd.exe takes it as it is.
local function probe_line(s)
    if MODE == "sh" then
        return sh_line(s)
    end
    return s
end

local function succeeded(r)
    return r == true or r == 0
end

local function has_nul(s)
    return s:find("%z") ~= nil
end

local function env(name)
    local value = os.getenv(name)
    if value ~= "" then return value end
    return nil
end

local function join(dir, name)
    local last = dir:sub(-1)
    if last == "/" or last == "\\" then return dir .. name end
    if MODE == "cmd" then return dir .. "\\" .. name end
    return dir .. "/" .. name
end

-- stdout of a shell command, or nil when io.popen fails
local function capture(cmd)
    local ok, h = pcall(io.popen, cmd, "r")
    if not (ok and h) then return nil end
    local out = h:read("*a") or ""
    h:close()
    return out
end

local function check_argv(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("sh.popen: argv must be a non-empty array of strings", 3)
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            error("sh.popen: argv[" .. i .. "] is not a string", 3)
        end
        if has_nul(argv[i]) then
            error("sh.popen: argv[" .. i .. "] contains a NUL byte", 3)
        end
    end
end

local function popen_works()
    if popen_ok == nil then
        local ok, h = pcall(io.popen, probe_line("exit 0"), "r")
        if not ok then
            -- interpreters built without popen raise "'popen' not supported"
            popen_ok  = false
            popen_why = "io.popen is not supported by this interpreter"
        elseif h then
            h:close()
            popen_ok = true
        else
            return false, "io.popen failed"
        end
    end
    return popen_ok, popen_why
end

-- h:close() returns true, "exit", code on Lua 5.2 and newer but only true
-- on Lua 5.1 and LuaJIT; a run with a known status tells which.
local function close_reports_status()
    if close_status == nil then
        local ok, h = pcall(io.popen, probe_line("exit 7"), "r")
        if not ok then
            close_status = false
        elseif h then
            local _, _, code = h:close()
            close_status = (code == 7)
        else
            return false   -- io.popen failed for now (EMFILE): ask again
        end
    end
    return close_status
end

local function close_code(how, code)
    if how == "exit" then return code end
    if how == "signal" then return 128 + code end
    return nil
end

-- The shell exits 126 when it finds the program but cannot execute it;
-- posix and luv report that as 127, like a program not found.
local function exit_code(code)
    if code == 126 then return NOT_RUN end
    return code
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- true, or nil and the reason
local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then
        return nil, "cannot write " .. tostring(err)
    end
    local written, werr = f:write(data)
    local closed, cerr  = f:close()
    if not (written and closed) then
        return nil, "cannot write " .. path .. ": " .. tostring(werr or cerr)
    end
    return true
end

--------------------------------------------------------------------------------
-- SHELL STRINGS
--------------------------------------------------------------------------------
-- A relative directory gets "./" in front, so cd neither searches CDPATH
-- nor reads "-" as $OLDPWD or a leading "-" as an option.
local function cd_target(dir)
    if dir:sub(1, 1) == "/" then return dir end
    return "./" .. dir
end

-- The shell line that prints the directory of the process, by MODE.
local PRINT_DIR = {
    sh  = sh_line("pwd -P", "pwd"),
    cmd = "cd",
}

-- The shell line that prints the absolute, resolved path of `dir`, taken
-- relative to `base` when given, and nothing when `dir` is not a directory
-- one can enter, by MODE. cmd.exe is best effort and untested.
local RESOLVE_DIR = {
    sh = function(base, dir)
        local steps = {}
        if base then
            steps[#steps + 1] = "cd -P " .. quote(cd_target(base))
        end
        steps[#steps + 1] = "cd -P " .. quote(cd_target(dir))
        steps[#steps + 1] = "pwd -P"
        local script = "(" .. table.concat(steps, " && ") .. ") 2>/dev/null"
        return sh_line(script, "cd pwd")
    end,
    cmd = function(base, dir)
        local steps = {}
        if base then steps[#steps + 1] = 'cd /d "' .. base .. '"' end
        steps[#steps + 1] = 'cd /d "' .. dir .. '"'
        steps[#steps + 1] = "cd"
        return "(" .. table.concat(steps, " && ") .. ") 2>NUL"
    end,
}

-- The line a shell line prints, without its line ending; nil when it
-- prints nothing or io.popen fails.
local function capture_line(cmd)
    local out = capture(cmd)
    if out == nil then return nil end
    out = out:gsub("[\r\n]+$", "")
    if out == "" then return nil end
    return out
end

-- printf is a builtin, so the input never passes through exec. Input with
-- NUL bytes, which a C string cannot carry, goes through %b as ASCII: each
-- backslash doubled, each NUL and each byte from 0x80 up written as \0ooo.
-- In multibyte locales such as SJIS and GBK, bash would otherwise read a
-- byte from 0x80 up and the backslash after it as one character.
local function printf_input(data)
    if not has_nul(data) then
        return "printf '%s' " .. quote(data)
    end
    local escaped = data:gsub("\\", "\\\\"):gsub("%z", "\\0000")
    escaped = escaped:gsub("[\128-\255]", function(c)
        return string.format("\\0%03o", c:byte())
    end)
    return "printf '%b' " .. quote(escaped)
end

-- POSIX sh. The inner subshell `( cd -P ... || exit 127; exec <argv> )`
-- runs the program found on PATH and keeps the cd to itself. The outer
-- subshell waits for it instead of exec'ing it, since a command follows,
-- and sends the shell's own diagnostics to /dev/null, such as the
-- "Killed: 9" that bash and dash print for a child killed by a signal;
-- because the redirections belong to the inner subshell, dash cannot
-- write that line into the captured stderr either. A failed cd or a
-- missing program reports to the captured stderr. The status goes to fd
-- 3, which the outer subshell opens before the program starts and the
-- program does not inherit.
local function render_sh(argv, files, cwd)
    local words = {}
    for i, a in ipairs(argv) do
        words[i] = quote(a)
    end
    if argv[1]:sub(1, 1) == "-" and argv[1]:find("/", 1, true) then
        -- exec would read "-x/prog" as an option; "./-x/prog" is the same
        words[1] = quote("./" .. argv[1])
    end
    local s = "exec " .. table.concat(words, " ")
    if cwd then
        s = "cd -P " .. quote(cd_target(cwd)) .. " || exit 127; " .. s
    end
    s = "( " .. s .. " )"
    if files.data == nil then
        s = s .. " < " .. (files.input and quote(files.input) or "/dev/null")
    end
    if files.stderr then
        s = s .. " 2> " .. quote(files.stderr)
    else
        s = s .. " 2>&1"
    end
    if files.status then
        s = (
            "( " .. s .. " 3>&-; echo \"$?\" >&3 ) 2>/dev/null 3> "
            .. quote(files.status)
        )
    else
        s = "( " .. s .. "; exit $? ) 2>/dev/null"
    end
    if files.data then
        -- A program that stops reading leaves printf a write error, not
        -- SIGPIPE, and `|| :` drops it, so under an exported pipefail the
        -- pipeline's status is still the program's.
        s = (
            "{ trap '' PIPE; " .. printf_input(files.data)
            .. " || :; } 2>/dev/null | " .. s
        )
    end
    return sh_line(s, "cd echo printf")
end

-- WINDOWS VARIANT, BEST EFFORT, UNTESTED: no Windows machine was available
-- during development. cmd.exe syntax: arguments in double quotes with an
-- embedded " doubled (cmd.exe still expands %VAR% inside them), NUL for
-- /dev/null. `call echo %^errorlevel%` expands errorlevel when the echo
-- runs, not when the line is read. The line gets one more pair of quotes
-- because `cmd /c` strips the first and the last quote of a line that
-- starts with one. There is no inline-input form (strategy basic).
local function render_cmd(argv, files, cwd)
    local function q(s)
        return '"' .. (s:gsub('"', '""')) .. '"'
    end
    if files.data then
        error("sh.popen: strategy basic needs a POSIX shell", 0)
    end
    local words = {}
    for i, a in ipairs(argv) do
        words[i] = q(a)
    end
    local s = table.concat(words, " ")
    if cwd then
        s = "cd /d " .. q(cwd) .. " && " .. s
    end
    s = s .. " < " .. (files.input and q(files.input) or "NUL")
    if files.stderr then
        s = s .. " 2> " .. q(files.stderr)
    else
        s = s .. " 2>&1"
    end
    if files.status then
        s = s .. " & call echo %^errorlevel% > " .. q(files.status)
    end
    return '"' .. s .. '"'
end

local function render(argv, files, cwd, mode)
    if (mode or MODE) == "cmd" then
        return render_cmd(argv, files or {}, cwd)
    end
    return render_sh(argv, files or {}, cwd)
end

--------------------------------------------------------------------------------
-- TEMP ROOTS AND THE PRIVATE DIRECTORY
--------------------------------------------------------------------------------
-- A directory in which this process may create files. Cached per root
-- until the next configure().
local function writable_dir(root)
    if MODE == "cmd" then
        return true   -- best effort: cmd.exe has no cheap write test
    end
    if probed[root] == nil then
        local q = quote(root)
        probed[root] = succeeded(os.execute(sh_line(
            "test -d " .. q .. " && test -w " .. q .. " && test -x " .. q,
            "test"
        )))
    end
    return probed[root]
end

local function usable(root)
    return dirs[root] ~= nil or writable_dir(root)
end

-- The root of a file strategy's private directory, or nil and why not.
-- standard takes a configured tmpdir alone; otherwise the first usable of
-- TMPDIR, TMP, TEMP and /tmp, so a stale TMPDIR does not push "auto" down
-- to basic.
local function temp_root(strategy)
    if strategy == "shmem" then
        if MODE == "sh" and usable("/dev/shm") then
            return "/dev/shm"
        end
        return nil, "/dev/shm is not a writable directory"
    end
    if config.tmpdir then
        if usable(config.tmpdir) then
            return config.tmpdir
        end
        return nil, config.tmpdir .. " is not a writable directory"
    end
    for _, var in ipairs({ "TMPDIR", "TMP", "TEMP" }) do
        local root = env(var)
        if root and usable(root) then
            return root
        end
    end
    if MODE == "sh" and usable("/tmp") then
        return "/tmp"
    end
    return nil, "no writable temp directory (TMPDIR, TMP, TEMP, /tmp)"
end

-- Relative roots are made absolute, so the paths in the shell string stay
-- valid after the `cd` of opts.cwd.
local function absolute(path)
    if MODE == "cmd" or path:sub(1, 1) == "/" then
        return path
    end
    local cwd = capture_line(PRINT_DIR[MODE])
    if not cwd then return path end
    return join(cwd, path)
end

-- The pid of the shell that echoes it: unique while it runs, which is all
-- a name prefix needs. Asked again next time when io.popen fails.
local function process_id()
    if pid == nil and MODE ~= "sh" then
        pid = false
    end
    if pid == nil then
        local out = capture(sh_line("echo $$", "echo"))
        if out then
            pid = out:match("%d+") or false
        end
    end
    return pid or false
end

-- Lua 5.1 and LuaJIT start math.random from the same seed in every
-- process, so seed it once, at the first private directory. This reseeds
-- the host's math.random too (docs/DESIGN.md section 6.3).
local function random_digits()
    if not seeded then
        seeded = true
        local digits = tostring({}):gsub("%D", "")
        local seed   = (
            os.time() + math.floor(os.clock() * 1000000)
            + (tonumber(digits:sub(-9)) or 0)
        )
        math.randomseed(math.floor(seed % 2147483647))
    end
    return string.format("%d", math.random(100000000, 999999999))
end

-- 32 hex digits that no other user can predict, from /dev/urandom; where
-- there is none (Windows), 27 decimal digits from math.random, which a
-- determined user could predict.
local function secret()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub(".", function(c)
                return string.format("%02x", c:byte())
            end))
        end
    end
    return random_digits() .. random_digits() .. random_digits()
end

local function register_sentinel()
    if sentinel then return end
    local function finalize()
        M.cleanup_all()
    end
    if newproxy then
        -- Lua 5.1 and LuaJIT run __gc for userdata only
        sentinel = newproxy(true)
        getmetatable(sentinel).__gc = finalize
    else
        sentinel = setmetatable({}, { __gc = finalize })
    end
end

local function remove_dir(path)
    if MODE == "cmd" then
        os.execute('rmdir /s /q "' .. path .. '" 2>NUL')
    else
        os.execute(sh_line("rm -rf " .. quote(path) .. " 2>/dev/null", "rm"))
    end
end

-- The directory is the one this process made: only that one holds the
-- marker, whose name nobody else knows. Opening a name that is not there
-- cannot block, unlike reading a FIFO someone put in a known place.
local function still_ours(entry)
    local f = io.open(entry.marker, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

-- Makes a private directory under root, or returns nil and why not.
-- mkdir fails when the name exists: then another suffix is tried.
local function make_dir(root)
    local base   = absolute(root)
    local id     = process_id()
    local prefix = "luash-"
    if id then
        prefix = prefix .. id .. "-"
    end
    for _ = 1, MAX_TRIES do
        local path = join(base, prefix .. random_digits())
        local cmd
        if MODE == "cmd" then
            cmd = 'mkdir "' .. path .. '" 2>NUL'
        else
            cmd = sh_line(
                "mkdir -m 700 " .. quote(path) .. " 2>/dev/null", "mkdir"
            )
        end
        if succeeded(os.execute(cmd)) then
            local entry   = { path = path }
            entry.marker  = join(path, ".luash-" .. secret())
            local written, why = write_file(entry.marker, "")
            if not written then
                remove_dir(path)
                return nil, why
            end
            made[#made + 1] = entry
            register_sentinel()
            return entry
        end
    end
    return nil, (
        "cannot create a private directory in " .. base
        .. " (" .. MAX_TRIES .. " attempts)"
    )
end

-- The private directory under root, or nil and why not. One that lost its
-- marker is left alone (cleanup_all still tries it) and a new one is made.
local function private_dir(root)
    local entry = dirs[root]
    if entry and still_ours(entry) then
        return entry
    end
    dirs[root] = nil
    local fresh, why = make_dir(root)
    if not fresh then
        return nil, why
    end
    dirs[root] = fresh
    return fresh
end

--------------------------------------------------------------------------------
-- STRATEGIES
--------------------------------------------------------------------------------
local function strategy_available(name)
    if name == "minimal" then
        return true
    end
    if name == "basic" then
        if MODE == "cmd" then
            return false, "strategy basic needs a POSIX shell"
        end
        return true
    end
    local root, why = temp_root(name)
    if not root then
        return false, why
    end
    return true
end

local function resolve()
    if resolved then
        return resolved
    end
    local name = config.strategy
    if name ~= "auto" then
        local ok, why = strategy_available(name)
        if not ok then
            return nil, "strategy " .. name .. " unavailable: " .. why
        end
        resolved = name
        return resolved
    end
    for _, candidate in ipairs(ORDER) do
        -- a configured tmpdir says where temp files go: not /dev/shm
        local skip = (candidate == "shmem" and config.tmpdir ~= nil)
        if not skip and strategy_available(candidate) then
            resolved = candidate
            return resolved
        end
    end
    return nil, "no strategy available"
end

--------------------------------------------------------------------------------
-- RUNNING
--------------------------------------------------------------------------------
-- The longest command line exec takes here, measured once: ARG_MAX less
-- the environment (its strings, a pointer to each and room for the rest of
-- sh's arguments; ARG_SLACK when its size is unknown), and on Linux at
-- most 32 pages less one byte, the limit for a single argument
-- (MAX_ARG_STRLEN), which the command line is to `sh -c`. macOS and the
-- BSDs have no per-argument limit. The environment env lists holds the
-- variables the shell adds as well, which errs on the safe side.
local function command_limit()
    if cmd_limit == nil and MODE == "sh" then
        -- one line per value, "-" where a command fails
        local out = capture(sh_line(
            "getconf ARG_MAX 2>/dev/null || echo -;"
            .. " getconf PAGESIZE 2>/dev/null || echo -;"
            .. " uname -s 2>/dev/null || echo -;"
            .. " env | wc -c; env | wc -l",
            "getconf uname env wc echo"
        ))
        if not out then
            return false   -- io.popen failed for now: measure next time
        end
        local lines = {}
        for line in out:gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        local arg_max   = tonumber(lines[1] or "")
        local page      = tonumber(lines[2] or "")
        local env_bytes = tonumber((lines[4] or ""):match("%d+") or "")
        local env_count = tonumber((lines[5] or ""):match("%d+") or "")
        local reserve   = ARG_SLACK
        if env_bytes and env_count and env_bytes > 0 then
            reserve = env_bytes + 8 * (env_count + 4) + 4096
        end
        local limit = false
        if arg_max and arg_max > reserve then
            limit = arg_max - reserve
        end
        if lines[3] == "Linux" and page then
            local per_arg = 32 * page - 1
            if not limit or per_arg < limit then
                limit = per_arg
            end
        end
        cmd_limit = limit
    end
    return cmd_limit or false
end

-- Runs the shell string cmd and reads its stdout to the end, passing each
-- chunk to on_stdout. Returns stdout and what h:close() reported (how,
-- code), or nil and the reason the command could not be started.
local function execute(cmd, on_stdout)
    if #cmd > ARG_SLACK then
        -- macOS and older glibc start the shell in a forked child, where
        -- an exec that fails for length goes unreported: check first.
        -- Shorter lines skip the check, which costs a shell once.
        local limit = command_limit()
        if limit and #cmd > limit then
            return nil, (
                "the command line (" .. #cmd .. " bytes) is longer than"
                .. " the system accepts (" .. limit .. " bytes)"
            )
        end
    end
    local h, err = io.popen(cmd, "r")
    if not h then
        -- the message is "<command line>: <reason>"; keep the reason
        local text = tostring(err)
        return nil, text:match(".*: (.-)$") or text
    end
    local chunks = {}
    local ok, perr = pcall(function()
        while true do
            local chunk = h:read(CHUNK)
            if not chunk then break end
            chunks[#chunks + 1] = chunk
            if on_stdout then on_stdout(chunk) end
        end
    end)
    -- close also when a callback raised, so the child is not left behind
    local _, how, code = h:close()
    if not ok then
        error(perr, 0)
    end
    return table.concat(chunks), how, code
end

-- Result for a command that could not be started.
local function failure(argv, reason, opts)
    local stderr = "sh.popen: " .. argv[1] .. ": " .. reason .. "\n"
    if opts.on_stderr then
        opts.on_stderr(stderr)
    end
    return {
        exitcode = NOT_RUN, signal = 0,
        stdout   = "",      stderr = stderr,
        cause    = "failed",
    }
end

-- Runs argv with its files in the private directory entry. Returns the
-- result and whether the directory was still this process's afterwards.
local function run_with_files(entry, argv, input, opts, files)
    if files.input then
        local written, why = write_file(files.input, input)
        if not written then
            return failure(argv, why, opts), true
        end
    end
    local cmd = render(argv, files, opts.cwd, MODE)
    local stdout, how, code = execute(cmd, opts.on_stdout)
    if not stdout then
        return failure(argv, how, opts), true
    end
    local ours   = still_ours(entry)
    local stderr = ""
    local status = nil
    if ours then
        stderr = read_file(files.stderr) or ""
        status = tonumber((read_file(files.status) or ""):match("%d+"))
    end
    if not status then
        -- the shell was killed, or the directory vanished during the run:
        -- what close() reports is the shell's status, not the program's
        status = (how == "signal") and 128 + code or NOT_RUN
        stderr = stderr .. "sh.popen: " .. argv[1] .. ": no exit status"
        if not ours then
            stderr = stderr .. " (the private directory vanished)"
        end
        stderr = stderr .. "\n"
    end
    if stderr ~= "" and opts.on_stderr then
        opts.on_stderr(stderr)
    end
    local result = {
        exitcode = exit_code(status), signal = 0,
        stdout   = stdout,            stderr = stderr,
        cause    = "exited",
    }
    return result, ours
end

-- shmem and standard: stdin, stderr and exit status through files in the
-- private directory under root.
local function run_files(root, argv, input, opts)
    local entry, why = private_dir(root)
    if not entry then
        return failure(argv, why, opts)
    end
    counter = counter + 1
    local n     = tostring(counter)
    local files = {
        stderr = join(entry.path, "err-" .. n),
        status = join(entry.path, "st-" .. n),
    }
    if input ~= "" then
        files.input = join(entry.path, "in-" .. n)
    end
    local ok, result, ours = pcall(
        run_with_files, entry, argv, input, opts, files
    )
    if not ok then
        ours = still_ours(entry)
    end
    if ours then
        -- never remove names in a directory someone else made
        for _, path in pairs(files) do
            os.remove(path)
        end
    end
    if not ok then
        error(result, 0)
    end
    return result
end

-- basic and minimal: stderr merged into stdout, status from h:close().
local function run_merged(argv, input, opts)
    local files = {}
    if input ~= "" then
        files.data = input
    end
    local cmd = render(argv, files, opts.cwd, MODE)
    local stdout, how, code = execute(cmd, opts.on_stdout)
    if not stdout then
        return failure(argv, how, opts)
    end
    local exitcode = 0
    if close_reports_status() then
        exitcode = exit_code(close_code(how, code) or 0)
    end
    return {
        exitcode = exitcode, signal = 0,
        stdout   = stdout,   stderr = "",
        cause    = "exited",
    }
end

--------------------------------------------------------------------------------
-- PUBLIC FUNCTIONS
--------------------------------------------------------------------------------
---Reports whether io.popen works and the configured strategy can run.
---@return boolean available
---@return string|nil reason  why not, when available is false
function M.available()
    local works, why = popen_works()
    if not works then
        return false, why
    end
    local name, reason = resolve()
    if not name then
        return false, reason
    end
    return true
end

---Describes the resolved strategy (docs/DESIGN.md section 5).
---@return table capabilities  name, strategy, stdin, separate_stderr,
---                            streaming, exitcode, signals
function M.capabilities()
    local name = resolve() or config.strategy
    local s    = STRATEGIES[name] or STRATEGIES.minimal
    return {
        name            = "popen",
        strategy        = name,
        stdin           = s.stdin,
        separate_stderr = s.files,
        streaming       = true,
        exitcode        = s.files or close_reports_status(),
        signals         = false,
    }
end

---Sets the strategy and temp root; fields left out take their defaults.
---@param opts table|nil  strategy: "auto" (default), "shmem", "standard",
---                       "basic" or "minimal"; tmpdir: root for the private
---                       directory of "standard", and "auto" then skips
---                       "shmem", which always uses /dev/shm; default: the
---                       first writable of TMPDIR, TMP, TEMP and /tmp
function M.configure(opts)
    opts = opts or {}
    local strategy = opts.strategy or "auto"
    if strategy ~= "auto" and not STRATEGIES[strategy] then
        error("sh.popen: unknown strategy " .. tostring(strategy), 2)
    end
    local tmpdir = opts.tmpdir
    if tmpdir ~= nil and (type(tmpdir) ~= "string" or tmpdir == "") then
        error("sh.popen: tmpdir must be a non-empty string", 2)
    end
    config.strategy = strategy
    config.tmpdir   = tmpdir
    resolved        = nil
    probed          = {}
end

---Changes the directory that run() enters when opts.cwd is nil (emulated
---`cd`: io.popen has no chdir). `dir` is taken relative to that directory.
---@param dir string
---@return true|nil ok
---@return string|nil err  when `dir` is not a directory one can enter
function M.chdir(dir)
    if type(dir) ~= "string" or dir == "" or has_nul(dir) then
        return nil, "sh.popen.chdir: expected a directory name"
    end
    local path = capture_line(RESOLVE_DIR[MODE](emulated, dir))
    if not path then
        return nil, dir .. ": cannot change directory"
    end
    emulated = path
    return true
end

---The directory run() enters: the one chdir() moved to, else that of the
---process.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    if emulated then return emulated end
    local path = capture_line(PRINT_DIR[MODE])
    if not path then
        return nil, "sh.popen.getcwd: cannot read the working directory"
    end
    return path
end

---Lists the strategies that can run here, most capable first.
---@return string[] names
function M.available_strategies()
    local names = {}
    if not popen_works() then
        return names
    end
    for _, name in ipairs(ORDER) do
        if strategy_available(name) then
            names[#names + 1] = name
        end
    end
    return names
end

---Removes the private directories and every file in them. The next run
---of a file strategy makes a new directory. A run in progress at that
---moment loses its stderr and exit status: it reports exit code 127 and
---"the private directory vanished".
function M.cleanup_all()
    for _, entry in ipairs(made) do
        -- only a directory that still holds this process's marker
        if still_ours(entry) then
            remove_dir(entry.path)
        end
    end
    made = {}
    dirs = {}
end

---Runs argv[1], found on PATH, with the remaining elements as arguments.
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  stdin for the child; "" or nil for none
---@param opts table|nil  on_stdout(chunk), on_stderr(chunk), cwd (default:
---                       the directory chdir() moved to)
---@return table result  exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    input = input or ""
    opts  = opts or {}
    if type(input) ~= "string" then
        error("sh.popen: input must be a string", 2)
    end
    local cwd = opts.cwd
    if cwd ~= nil and (type(cwd) ~= "string" or has_nul(cwd)) then
        error("sh.popen: cwd must be a string without NUL bytes", 2)
    end
    local name, why = resolve()
    if not name then
        return failure(argv, why, opts)
    end
    if not STRATEGIES[name].stdin and input ~= "" then
        error(
            "sh.popen: strategy " .. name .. " cannot pass input to "
            .. argv[1], 2
        )
    end
    if cwd == "" then
        -- chdir("") fails, but `cd ''` stays put in some shells
        return failure(argv, "cannot change to an empty directory name", opts)
    end
    if cwd == nil then cwd = emulated end
    opts = {
        on_stdout = opts.on_stdout, on_stderr = opts.on_stderr, cwd = cwd,
    }
    if argv[1]:sub(1, 1) == "-" and not argv[1]:find("/", 1, true) then
        -- exec would read it as an option, and has no portable "--"
        return failure(
            argv, "a program name starting with - cannot be run by sh", opts
        )
    end
    if not STRATEGIES[name].files then
        return run_merged(argv, input, opts)
    end
    local root, reason = temp_root(name)
    if not root then
        return failure(argv, reason, opts)
    end
    return run_files(root, argv, input, opts)
end

---Builds the shell string for one run; exposed for the tests.
---@param argv string[]
---@param files table|nil  input, stderr, status: absolute paths of the temp
---                        files; data: input given on the command line
---                        (basic); nil or {} for minimal
---@param cwd string|nil  directory to cd into first
---@param mode string|nil  "sh" (POSIX) or "cmd" (Windows); default: this
---                        platform
---@return string command
function M._render(argv, files, cwd, mode)
    return render(argv, files, cwd, mode)
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.backend.posix" ] = function( ... ) local arg = _G.arg;
-- luaposix process backend for LuaSH (docs/DESIGN.md sections 4, 6.1).
--
-- run() forks, connects three pipes to the child's stdin, stdout and
-- stderr, and execs the program found on PATH. The parent then runs one
-- poll loop that writes the input in slices as the child reads it and
-- collects both outputs as they arrive, so input and output of any size
-- flow without deadlock. SIGPIPE is ignored in the parent while the loop
-- runs: a child that exits before reading all of its input turns the
-- next write into EPIPE instead of killing the host.
--
-- A fourth pipe, closed on exec, tells a program that could not be
-- started (cause "failed") apart from one that exits with status 127.
--
-- chdir() and getcwd() are posix.chdir and posix.getcwd: `cd` changes the
-- directory of the process.
--
-- luaposix is loaded with pcall: without it this module still loads and
-- available() returns false with the reason.
local M = { name = "posix" }

local ok, posix = pcall(require, "posix")

-- execp comes from posix.unistd. The top-level posix.execp was a wrapper
-- kept for compatibility with luaposix 32 and earlier, and luaposix 38
-- replaced it with a function that only raises an error. The wrapper
-- called posix.unistd.execp, which takes the same (path, argt) arguments
-- in luaposix 36.3 and 38.
local execp = nil
if ok then
    local found, unistd = pcall(require, "posix.unistd")
    if found and type(unistd) == "table" then execp = unistd.execp end
end

local READ_SIZE  = 4096    -- bytes per read from stdout or stderr
local WRITE_SIZE = 65536   -- at most this many input bytes per write

-- Every field of the posix module that this module uses (execp, above,
-- comes from posix.unistd).
local REQUIRED = {
    "_exit", "chdir", "close", "dup2", "errno", "fcntl", "fork", "getcwd",
    "pipe", "poll", "read", "signal", "wait", "write",
    "EAGAIN", "EINTR", "EPIPE", "FD_CLOEXEC", "F_SETFD", "F_SETFL",
    "O_NONBLOCK", "SIGPIPE", "SIG_IGN",
}

-- require's error message on one line, without the paths it searched.
local function one_line(msg)
    msg = msg:gsub("\n\tno [^\n]*", "")
    msg = msg:gsub("%s*\n%s*", " ")
    return (msg:gsub(":%s*$", ""))
end

-- Why this backend cannot run here, or nil when it can.
local unavailable = nil
if not ok then
    unavailable = one_line(tostring(posix))
elseif type(execp) ~= "function" then
    unavailable = "luaposix has no posix.unistd.execp"
else
    for _, key in ipairs(REQUIRED) do
        if posix[key] == nil then
            unavailable = "luaposix has no posix." .. key
            break
        end
    end
end

-- The host's SIGPIPE disposition while a run has replaced it with SIG_IGN,
-- nil otherwise. A child started by a nested run (one started from an
-- output callback) gets it back before exec, since exec keeps SIG_IGN.
local host_sigpipe = nil

local function check_argv(argv)
    if type(argv) ~= "table" or argv[1] == nil then
        error("sh.backend.posix.run: argv must be a non-empty array", 3)
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            error(
                "sh.backend.posix.run: argv[" .. i .. "] is not a string", 3
            )
        end
    end
end

-- Closes every descriptor in t, a table of descriptors by name.
local function close_all(t)
    for key, fd in pairs(t) do
        posix.close(fd)
        t[key] = nil
    end
end

-- Opens the stdin, stdout, stderr and status pipes. Returns their eight
-- descriptors by name (in_r, in_w, out_r, ...), or nil and the error
-- after closing those already open.
local function open_pipes()
    local fds = {}
    for _, name in ipairs({ "in", "out", "err", "st" }) do
        local r, w = posix.pipe()
        if r == nil then
            close_all(fds)
            return nil, w
        end
        fds[name .. "_r"] = r
        fds[name .. "_w"] = w
    end
    return fds
end

-- Runs in the forked child: moves the pipe ends onto descriptors 0, 1 and
-- 2, changes directory and execs the program. Returns only on failure,
-- with the reason.
local function exec_child(fds, program, args, cwd)
    posix.close(fds.in_w)
    posix.close(fds.out_r)
    posix.close(fds.err_r)
    posix.close(fds.st_r)
    posix.dup2(fds.in_r, 0)
    posix.dup2(fds.out_w, 1)
    posix.dup2(fds.err_w, 2)
    -- Close the spare originals. An end that landed on 0, 1 or 2 (the
    -- host had closed that descriptor) is already in use as one of them.
    for _, fd in ipairs({ fds.in_r, fds.out_w, fds.err_w }) do
        if fd > 2 then posix.close(fd) end
    end
    if host_sigpipe ~= nil then
        posix.signal(posix.SIGPIPE, host_sigpipe)
    end
    if cwd ~= nil then
        local done, err = posix.chdir(cwd)
        if done == nil then return err end
    end
    local _, _, errno = execp(program, args)
    return (posix.errno(errno))
end

-- Starts argv[1] in a child process. Returns a job table with the pid and
-- the parent's ends of the pipes, or nil and the reason it failed.
local function spawn(argv, cwd)
    local args = {}
    for i = 2, #argv do
        args[i - 1] = argv[i]
    end
    local fds, err = open_pipes()
    if fds == nil then return nil, "pipe: " .. tostring(err) end
    -- Close on exec keeps the parent's ends out of children that a nested
    -- run starts, and closes the status pipe once exec has succeeded.
    for _, key in ipairs({ "in_w", "out_r", "err_r", "st_r", "st_w" }) do
        posix.fcntl(fds[key], posix.F_SETFD, posix.FD_CLOEXEC)
    end

    local pid, ferr = posix.fork()
    if pid == nil then
        close_all(fds)
        return nil, "fork: " .. tostring(ferr)
    end
    if pid == 0 then
        -- Never raise here: a Lua error would unwind through the child's
        -- copy of the host program. _exit skips the host's stdio buffers.
        local _, reason = pcall(exec_child, fds, argv[1], args, cwd)
        local text = "sh: " .. argv[1] .. ": " .. tostring(reason) .. "\n"
        pcall(posix.write, 2, text)
        pcall(posix.write, fds.st_w, "x")
        posix._exit(127)
    end

    posix.close(fds.in_r)
    posix.close(fds.out_w)
    posix.close(fds.err_w)
    posix.close(fds.st_w)
    return {
        name  = argv[1],  pid    = pid,       status = fds.st_r,
        stdin = fds.in_w, stdout = fds.out_r, stderr = fds.err_r,
        out   = {},       err    = {},   -- chunks of stdout and stderr
    }
end

-- True when poll reported anything for this entry: data, space, hang-up,
-- error or a closed descriptor. read or write then tells which.
local function woke(entry)
    local ev = entry.revents
    return ev ~= nil and (ev.IN or ev.OUT or ev.HUP or ev.ERR or ev.NVAL)
end

-- Writes input to the child and reads its stdout and stderr in one poll
-- loop until all three pipes are closed: input fully written or refused,
-- both outputs at EOF. Chunks go to job.out and job.err and to the
-- callbacks in opts.
local function pump(job, input, opts)
    local pollfds = {}
    local pos     = 1   -- next byte of input to write

    local function finish(key)
        pollfds[job[key]] = nil
        posix.close(job[key])
        job[key] = nil
    end

    local function feed()
        local slice = input:sub(pos, pos + WRITE_SIZE - 1)
        local n, _, errno = posix.write(job.stdin, slice)
        if n ~= nil then
            pos = pos + n
            if pos > #input then finish("stdin") end
        elseif errno ~= posix.EAGAIN and errno ~= posix.EINTR then
            finish("stdin")   -- EPIPE: the child no longer reads stdin
        end
    end

    local function drain(key, chunks, callback)
        local chunk, _, errno = posix.read(job[key], READ_SIZE)
        local again = errno == posix.EINTR or errno == posix.EAGAIN
        if chunk == nil and again then return end
        if chunk == nil or chunk == "" then
            finish(key)
        else
            chunks[#chunks + 1] = chunk
            if callback then callback(chunk) end
        end
    end

    if input == "" then
        finish("stdin")
    else
        posix.fcntl(job.stdin, posix.F_SETFL, posix.O_NONBLOCK)
        pollfds[job.stdin] = { events = { OUT = true } }
    end
    pollfds[job.stdout] = { events = { IN = true } }
    pollfds[job.stderr] = { events = { IN = true } }

    while next(pollfds) ~= nil do
        local ready, msg, errno = posix.poll(pollfds, -1)
        if ready == nil and errno ~= posix.EINTR then
            -- Give up; run() closes the pipes, which ends the child's I/O.
            local text = "sh: " .. job.name .. ": poll: " .. tostring(msg)
            job.err[#job.err + 1] = text .. "\n"
            if opts.on_stderr then opts.on_stderr(text .. "\n") end
            return
        end
        if ready ~= nil then
            if job.stdin and woke(pollfds[job.stdin]) then feed() end
            if job.stdout and woke(pollfds[job.stdout]) then
                drain("stdout", job.out, opts.on_stdout)
            end
            if job.stderr and woke(pollfds[job.stderr]) then
                drain("stderr", job.err, opts.on_stderr)
            end
        end
    end
end

-- Waits for the child. Returns exitcode, signal and cause.
local function reap(job)
    local pid, how, code
    repeat
        pid, how, code = posix.wait(job.pid)
    until pid ~= nil or code ~= posix.EINTR
    -- The status pipe holds a byte when exec failed and is at EOF when
    -- exec closed it. The child has ended, so this read does not block.
    local mark, errno
    repeat
        mark, _, errno = posix.read(job.status, 1)
    until mark ~= nil or errno ~= posix.EINTR
    posix.close(job.status)
    local failed = mark ~= nil and mark ~= ""
    local cause  = failed and "failed" or "exited"

    -- No status (the host ignores SIGCHLD, say): success as far as known.
    if pid == nil then return failed and 127 or 0, 0, cause end
    if how == "exited" then return code, 0, cause end
    return 127, code, "killed"   -- "killed" or "stopped"
end

-- The result for a program whose process could not be created.
local function failure(name, reason, opts)
    local text = "sh: " .. name .. ": " .. reason .. "\n"
    if opts.on_stderr then opts.on_stderr(text) end
    return {
        exitcode = 127, signal = 0,    cause = "failed",
        stdout   = "",  stderr = text,
    }
end

---Reports whether luaposix is loaded and has every function this uses.
---@return boolean available
---@return string|nil reason  why not, when available is false
function M.available()
    if unavailable then return false, unavailable end
    return true
end

---Describes this backend (docs/DESIGN.md section 5).
---@return table capabilities  a new table on each call
function M.capabilities()
    return {
        name            = "posix",
        strategy        = nil,
        stdin           = true,
        separate_stderr = true,
        streaming       = true,
        exitcode        = true,
        signals         = true,
    }
end

---Accepts and ignores options; this backend has none.
---@param _ table|nil
function M.configure(_)
end

---Changes the working directory of the process.
---@param dir string
---@return true|nil ok
---@return string|nil err  "<dir>: No such file or directory"
function M.chdir(dir)
    if unavailable then
        error("sh.backend.posix.chdir: " .. unavailable, 2)
    end
    local done, err = posix.chdir(dir)
    if done then return true end
    return nil, err
end

---The working directory of the process.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    if unavailable then
        error("sh.backend.posix.getcwd: " .. unavailable, 2)
    end
    return posix.getcwd()
end

---Runs argv[1], found on PATH, with argv[2], ... as its arguments. A
---program that cannot be started gives exitcode 127, cause "failed" and
---the reason in stderr; only an invalid argv raises.
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  written to the child's stdin, which then closes
---@param opts table|nil  on_stdout(chunk), on_stderr(chunk), cwd
---@return table result  exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    if unavailable then
        error("sh.backend.posix.run: " .. unavailable, 2)
    end
    input = input == nil and "" or tostring(input)
    opts  = opts or {}

    local job, reason = spawn(argv, opts.cwd)
    if job == nil then return failure(argv[1], reason, opts) end

    local previous = posix.signal(posix.SIGPIPE, posix.SIG_IGN)
    local outer    = host_sigpipe
    if outer == nil then host_sigpipe = previous end
    -- An error from a callback still closes the pipes, reaps the child and
    -- restores SIGPIPE before it propagates.
    local pumped, err = pcall(pump, job, input, opts)
    for _, key in ipairs({ "stdin", "stdout", "stderr" }) do
        if job[key] then posix.close(job[key]) end
    end
    local exitcode, signal, cause = reap(job)
    if previous ~= nil then posix.signal(posix.SIGPIPE, previous) end
    host_sigpipe = outer
    if not pumped then error(err, 0) end

    return {
        exitcode = exitcode,              signal = signal, cause = cause,
        stdout   = table.concat(job.out), stderr = table.concat(job.err),
    }
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.command" ] = function( ... ) local arg = _G.arg;
---
--- sh.command: the Command and Pipeline types of LuaSH, argument flattening
--- (DESIGN.md section 7), shell quoting and rendering (section 3.4).
---
--- This module starts no process and requires no other part of `sh`.
--- Command:run() and Pipeline:run() call the runner that sh/init.lua
--- installs with set_runner().
---
--- Rendering: a Pipeline renders its stages joined by " | ". The sources of
--- its first stage (the Pipelines of the Results that Command received)
--- render in front of it: one as "a | ", several as the group
--- "{ a; b; } | ". Every later stage reads the stage before it, so its own
--- sources are not rendered. Literal stdin is never rendered.
---
--- Pipeline:pipe() appends in place. To extend the Pipeline of an earlier
--- Result without changing that Result, build a new one with
--- Pipeline(r.__pipeline, cmd). Commands are mutable too; Command:copy()
--- gives a snapshot that later changes to the original do not reach.
---
--- The runner is called as runner(cmd, input) and returns a Result. `input`
--- is nil when the Command runs on its own (Command:run()): its stdin is
--- then `cmd.stdin` and its provenance `cmd.sources`. Pipeline:run() passes
--- the Result of the previous stage as `input` to every later stage; that
--- Result replaces `cmd.stdin` and `cmd.sources`. Both methods arrange that
--- error(msg, 2) in the runner, as DESIGN.md section 3.6 has it, points at
--- the line that called run(). A string error raised another way comes out
--- of an earlier stage with that position in front of its own, and out of
--- the last stage as raised; any other error value passes unchanged.
---
--- Errors in the arguments of a public function point at its caller.
---

local M = {}

local _tostring = tostring

-- Arguments matching this pattern render without quotes.
local BARE = "^[%w%-%._/=:@%%+,]+$"

local NO_RUNNER = "sh.command: no runner installed (require 'sh' first)"

-- The function installed with M.set_runner, nil until then.
local runner = nil

---@class sh.Command
---@field name string the program, argv[1]
---@field args string[] the arguments after the program
---@field stdin string data for the program's stdin, "" for none
---@field sources sh.Pipeline[] Pipelines whose output is in `stdin`
local Command = {}

---@class sh.Pipeline
---@field stages sh.Command[] the Commands, run left to right
local Pipeline = {}

local command_mt  = { __name = "sh.Command",  __index = Command }
local pipeline_mt = { __name = "sh.Pipeline", __index = Pipeline }

-- Call f(...) and return its first result. An error that f raises is
-- raised again at the caller of the public function that called guard():
-- a string with that position in front, any other value unchanged. That
-- function must not tail-call guard(), or the level is one off. The
-- helpers raise with level 0, so their messages carry no position yet.
local function guard(f, ...)
    local good, value = pcall(f, ...)
    if good then return value end
    if type(value) ~= "string" then error(value, 0) end
    error(value, 3)
end

--------------------------------------------------------------------------------
-- Recognition
--------------------------------------------------------------------------------

local function has_name(x, name)
    if type(x) ~= "table" then return false end
    local mt = getmetatable(x)
    return type(mt) == "table" and rawget(mt, "__name") == name
end

local function is_command(x)
    return has_name(x, "sh.Command")
end

local function is_pipeline(x)
    return has_name(x, "sh.Pipeline")
end

--- Whether `x` is a Command, judged by the `__name` of its metatable, so
--- that a Command from another copy of this module counts too.
---@param x any
---@return boolean
M.is_command = is_command

--- Whether `x` is a Pipeline, judged by the `__name` of its metatable.
---@param x any
---@return boolean
M.is_pipeline = is_pipeline

--------------------------------------------------------------------------------
-- Argument flattening (DESIGN.md section 7)
--------------------------------------------------------------------------------

local function append(list, items)
    for _, item in ipairs(items) do
        list[#list + 1] = item
    end
end

-- The stdin text of an `__input` value.
local function input_text(value)
    local kind = type(value)
    if kind == "string" then return value end
    if kind == "number" then return _tostring(value) end
    error("sh.command: __input must be a string, got " .. kind, 0)
end

-- The argument for flag `key` with `value`, or nil when it gives none.
local function format_flag(key, value)
    if key == "" then error("sh.command: empty flag name", 0) end
    local flag = (#key == 1) and ("-" .. key) or ("--" .. key)
    local kind = type(value)
    if value == true then
        return flag
    elseif value == false or value == nil then
        return nil
    elseif kind == "string" then
        return flag .. "=" .. value
    elseif kind == "number" then
        return flag .. "=" .. _tostring(value)
    end
    error("sh.command: bad " .. kind .. " value for flag '" .. key .. "'", 0)
end

-- Whether string `a` sorts before `b` in byte order. Lua's `<` on strings
-- follows the collation locale on PUC Lua (strcoll), so flag order would
-- depend on os.setlocale().
local function byte_less(a, b)
    local n = #a
    if #b < n then n = #b end
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

local walk  -- forward declaration; walk and walk_table recurse into each other

-- Walk table `t`: its array entries, then the known `__` fields, then its
-- flags in sorted key order. Entries and flags are read as `t[i]` and
-- `pairs` give them, so a proxy table works; the `__` fields are read raw,
-- so that a metatable of a Result cannot add any.
local function walk_table(t, out, active)
    local n = #t
    for i = 1, n do
        walk(t[i], out, active)
    end

    -- Integer keys past the border `#t` (entries after a nil) and flag keys
    -- are sorted, so that the order never depends on the table layout.
    local extra  = {}
    local keys   = {}
    local values = {}
    for k, v in pairs(t) do
        local kind = type(k)
        if kind == "number" and k > n and k % 1 == 0 then
            extra[#extra + 1] = k
            values[k]         = v
        elseif kind == "string" and k:sub(1, 1) ~= "_" then
            keys[#keys + 1] = k
            values[k]       = v
        end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do
        walk(values[k], out, active)
    end

    -- A Result is a table with a string `__stdout`.
    local fields = out.fields
    local input  = rawget(t, "__input")
    local stdout = rawget(t, "__stdout")
    local stderr = rawget(t, "__stderr")
    if input ~= nil then
        out.input = out.input .. input_text(input)
    end
    if type(stdout) == "string" then
        local pipeline = rawget(t, "__pipeline")
        fields.__stdout = fields.__stdout .. stdout
        if pipeline then out.sources[#out.sources + 1] = pipeline end
    end
    if type(stderr) == "string" then
        fields.__stderr = fields.__stderr .. stderr
    end
    if rawget(t, "__exitcode") ~= nil then
        fields.__exitcode = rawget(t, "__exitcode")
    end
    if rawget(t, "__signal") ~= nil then
        fields.__signal = rawget(t, "__signal")
    end

    table.sort(keys, byte_less)
    for _, k in ipairs(keys) do
        local flag = format_flag(k, values[k])
        if flag then out.args[#out.args + 1] = flag end
    end
end

-- Add one argument value to `out`. `active` holds the tables being walked,
-- so that a table containing itself raises instead of recursing forever.
function walk(value, out, active)
    local kind = type(value)
    if value == nil or value == false then
        return
    elseif kind == "string" then
        out.args[#out.args + 1] = value
    elseif kind == "number" then
        out.args[#out.args + 1] = _tostring(value)
    elseif kind ~= "table" then
        error("sh.command: invalid argument of type " .. kind, 0)
    elseif is_command(value) or is_pipeline(value) then
        error("sh.command: a Command is not an argument; use :pipe()", 0)
    elseif active[value] then
        error("sh.command: an argument table contains itself", 0)
    else
        active[value] = true
        walk_table(value, out, active)
        active[value] = nil
    end
end

-- Flatten the `n` argument values in `values`.
local function flatten(n, values)
    local out = {
        args    = {},
        input   = "",
        sources = {},
        fields  = { __stdout = "", __stderr = "" },
    }
    local active = {}
    for i = 1, n do
        walk(values[i], out, active)
    end
    return out
end

--- Flatten the arguments of a command call as DESIGN.md section 7 says.
--- Strings and numbers are positional, `nil` and `false` are skipped, tables
--- are walked depth first, their string keys are flags in sorted order. A
--- Result (a table with a string `__stdout`) adds its `__input` to `input`
--- and its `__pipeline` to `sources`; `fields` passes `__stdout`,
--- `__stderr` (concatenated) and `__exitcode`, `__signal` (the last seen)
--- through for the builtins.
---@param ... any
---@return table parsed { args, input, sources, fields }
function M.parse(...)
    local parsed = guard(flatten, select("#", ...), { ... })
    return parsed
end

--------------------------------------------------------------------------------
-- Quoting and rendering (DESIGN.md section 3.4)
--------------------------------------------------------------------------------

--- Quote one argument for a POSIX shell: bare when it matches
--- `^[%w%-%._/=:@%%+,]+$`, otherwise in single quotes with `'` as `'\''`.
---@param s string|number
---@return string
function M.quote(s)
    if type(s) == "number" then s = _tostring(s) end
    if type(s) ~= "string" then
        error("sh.command.quote: expected a string, got " .. type(s), 2)
    end
    if s:match(BARE) then return s end
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function render_words(cmd)
    local words = { M.quote(cmd.name) }
    for i, a in ipairs(cmd.args) do
        words[i + 1] = M.quote(a)
    end
    return table.concat(words, " ")
end

local render_stages  -- forward declaration; recurses through render_feed

-- The rendering of the sources of `cmd` followed by " | ", or "" when it
-- has none. `active` holds the Commands whose sources are being rendered
-- further up: a Command fed by a Pipeline it belongs to (possible because
-- Commands are mutable) renders its sources once instead of forever.
local function render_feed(cmd, active)
    if active[cmd] then return "" end
    active[cmd] = true
    local parts = {}
    for _, src in ipairs(cmd.sources) do
        local text = ""
        if is_pipeline(src) then
            text = render_stages(src.stages, active)
        elseif is_command(src) then
            text = render_stages({ src }, active)
        end
        if text ~= "" then parts[#parts + 1] = text end
    end
    active[cmd] = nil
    if #parts == 0 then return "" end
    if #parts == 1 then return parts[1] .. " | " end
    return "{ " .. table.concat(parts, "; ") .. "; } | "
end

function render_stages(stages, active)
    if #stages == 0 then return "" end
    local first = stages[1]
    local texts = { render_feed(first, active) .. render_words(first) }
    for i = 2, #stages do
        texts[i] = render_words(stages[i])
    end
    return table.concat(texts, " | ")
end

--- Render a Pipeline, or a Command as a one-stage Pipeline, as a shell
--- pipeline string; this is what `tostring` returns for both.
---@param x sh.Pipeline|sh.Command
---@return string
function M.render(x)
    if is_pipeline(x) then return render_stages(x.stages, {}) end
    if is_command(x) then return render_stages({ x }, {}) end
    error("sh.command.render: expected Pipeline or Command, got " .. type(x), 2)
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

--- Install the function that runs a Command; sh/init.lua does this when it
--- loads. It is called as fn(cmd, input) and returns a Result (see the
--- module comment). `nil` removes the runner.
---@param fn function|nil
---@return function|nil previous the runner installed before
function M.set_runner(fn)
    if fn ~= nil and type(fn) ~= "function" then
        error("sh.command.set_runner: expected a function, got " .. type(fn), 2)
    end
    local previous = runner
    runner = fn
    return previous
end

-- The installed runner; raises at the caller of the method that called it.
local function get_runner()
    if runner == nil then error(NO_RUNNER, 3) end
    return runner
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function new_command(name, args, stdin, sources)
    local cmd = { name = name, args = args, stdin = stdin, sources = sources }
    return setmetatable(cmd, command_mt)
end

--- A Command for program `name` with the arguments `...`, not executed. The
--- arguments are those of sh.name(...) (DESIGN.md section 7), so a flag
--- table or a Result works too.
---@param name string the program
---@param ... any arguments, flag tables, Results
---@return sh.Command
function M.Command(name, ...)
    if type(name) ~= "string" or name == "" then
        error("sh.command: Command name must be a non-empty string", 2)
    end
    local parsed = guard(flatten, select("#", ...), { ... })
    return new_command(name, parsed.args, parsed.input, parsed.sources)
end

--- Append arguments, flattened like those of M.Command.
---@param ... any
---@return sh.Command self
function Command:arg(...)
    local parsed = guard(flatten, select("#", ...), { ... })
    append(self.args, parsed.args)
    append(self.sources, parsed.sources)
    self.stdin = self.stdin .. parsed.input
    return self
end

--- Append flag `key`: `-k` for a one-character key, else `--key`; with
--- `=value` for a string or number value. Without a value it is a bare
--- flag; a value of nil or false adds nothing, as in a flag table.
---@param key string
---@param ... boolean|string|number|nil the value; none means true
---@return sh.Command self
function Command:flag(key, ...)
    if type(key) ~= "string" then
        error("sh.command: flag name must be a string, got " .. type(key), 2)
    end
    local value = true
    if select("#", ...) > 0 then value = ... end
    local flag = guard(format_flag, key, value)
    if flag then self.args[#self.args + 1] = flag end
    return self
end

--- Set the stdin of this Command, replacing any input it had, also that of
--- Results passed as arguments. A string is literal input; a Result gives
--- its `__input` and becomes the only source; `nil` clears the input.
---@param x string|table|nil
---@return sh.Command self
function Command:input(x)
    local kind = type(x)
    if x == nil then
        self.stdin   = ""
        self.sources = {}
    elseif kind == "string" or kind == "number" then
        self.stdin   = _tostring(x)
        self.sources = {}
    elseif kind == "table" and not (is_command(x) or is_pipeline(x)) then
        local is_result = type(rawget(x, "__stdout")) == "string"
        local data      = rawget(x, "__input")
        if data == nil and not is_result then
            error("sh.command: Command:input() needs a Result or __input", 2)
        end
        self.stdin   = (data == nil) and "" or guard(input_text, data)
        self.sources = { is_result and rawget(x, "__pipeline") or nil }
    else
        error("sh.command: invalid input of type " .. kind, 2)
    end
    return self
end

--- A new Command with the same program, arguments, stdin and sources.
--- Changing either one afterwards leaves the other as it was, so a copy
--- can record what ran.
---@return sh.Command
function Command:copy()
    local args    = {}
    local sources = {}
    append(args, self.args)
    append(sources, self.sources)
    return new_command(self.name, args, self.stdin, sources)
end

--- The argument vector, a new table: the program, then its arguments.
---@return string[]
function Command:argv()
    local argv = { self.name }
    for i, a in ipairs(self.args) do
        argv[i + 1] = a
    end
    return argv
end

--- Run this Command with the installed runner and return its Result. The
--- runner is tail-called, so its errors point at the caller of run().
---@return table Result
function Command:run()
    return get_runner()(self)
end

--------------------------------------------------------------------------------
-- Pipeline
--------------------------------------------------------------------------------

-- Append `x` to `stages`: a Command, or the stages of a Pipeline (counted
-- first, so that a Pipeline can be piped into itself).
local function add_stage(stages, x)
    if is_command(x) then
        stages[#stages + 1] = x
    elseif is_pipeline(x) then
        local list = x.stages
        local n    = #list
        for i = 1, n do
            stages[#stages + 1] = list[i]
        end
    else
        error("sh.command: cannot pipe a " .. type(x), 0)
    end
end

-- A Pipeline of the `n` Commands or Pipelines in `values`.
local function new_pipeline(n, values)
    local stages = {}
    for i = 1, n do
        add_stage(stages, values[i])
    end
    return setmetatable({ stages = stages }, pipeline_mt)
end

--- A Pipeline of the given Commands; a Pipeline argument adds its stages.
---@param ... sh.Command|sh.Pipeline
---@return sh.Pipeline
function M.Pipeline(...)
    local p = guard(new_pipeline, select("#", ...), { ... })
    return p
end

--- A new Pipeline: this Command, then `other` (a Command or Pipeline).
---@param other sh.Command|sh.Pipeline
---@return sh.Pipeline
function Command:pipe(other)
    local p = guard(new_pipeline, 2, { self, other })
    return p
end

--- Append a Command, or the stages of a Pipeline, to this Pipeline.
---@param x sh.Command|sh.Pipeline
---@return sh.Pipeline self
function Pipeline:pipe(x)
    guard(add_stage, self.stages, x)
    return self
end

--- The Command stages, in a new array.
---@return sh.Command[]
function Pipeline:commands()
    local list = {}
    append(list, self.stages)
    return list
end

--- Run the stages left to right, each with the Result of the one before as
--- its input, and return the Result of the last stage. The sources of the
--- first stage do not run again: their output is already in its stdin. A
--- string error of an earlier stage is raised again at the caller of run(),
--- and the last stage is tail-called, so runner errors point at that
--- caller.
---@return table Result
function Pipeline:run()
    local run    = get_runner()
    local stages = self.stages
    local n      = #stages
    if n == 0 then
        error("sh.command: cannot run an empty Pipeline", 2)
    end
    local result = nil
    for i = 1, n - 1 do
        local good, value = pcall(run, stages[i], result)
        if not good then
            if type(value) ~= "string" then error(value, 0) end
            error(value, 2)
        end
        result = value
    end
    return run(stages[n], result)
end

--------------------------------------------------------------------------------
-- Metamethods
--------------------------------------------------------------------------------

-- `a | b` on Lua 5.3 and newer; older interpreters ignore the metamethod.
local function bor(a, b)
    local p = guard(new_pipeline, 2, { a, b })
    return p
end

command_mt.__tostring  = M.render
command_mt.__bor       = bor
pipeline_mt.__tostring = M.render
pipeline_mt.__bor      = bor

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.pipe" ] = function( ... ) local arg = _G.arg;
---
--- sh.pipe: runs a command through the backend in use (DESIGN.md section
--- 6.4), with the verbose and trace plumbing of sh.config.
---
--- It reads the configuration table that sh/init.lua hands over with
--- set_config(): verbose, trace and sink, at each run. The backend comes
--- from sh.backend, which selected it when sh loaded or at
--- sh.set_backend(). This module never requires sh.init. run() is called
--- directly, not through sys.load_pcall: it calls config.sink, which may
--- use the commands that sh.install() provides.
---

local backend = require("sh.backend")

local M = {}

-- The configuration in use until init.lua calls set_config.
local config = {
    verbose      = false,
    trace        = false,
    raise_errors = true,
}

-- The on_stdout or on_stderr callback for verbose mode.
local function writer(stream, handle)
    local sink = config.sink
    if sink then
        return function(chunk) sink(stream, chunk) end
    end
    return function(chunk)
        handle:write(chunk)
        handle:flush()
    end
end

local function trace(argv, pipeline)
    local text = pipeline and tostring(pipeline) or table.concat(argv, " ")
    local line = "+ " .. text .. "\n"
    if config.sink then
        config.sink("trace", line)
        return
    end
    io.stderr:write(line)
    io.stderr:flush()
end

--- Use `tbl` as the configuration (sh.config); init.lua calls this.
---@param tbl table
function M.set_config(tbl)
    if type(tbl) ~= "table" then
        error("sh.pipe.set_config: expected a table, got a " .. type(tbl), 2)
    end
    config = tbl
end

--- Run `argv` with `input` on stdin through the backend in use and return
--- the backend's result table. Streams output when config.verbose is set
--- and writes the trace line when config.trace is set.
---@param argv string[] the program and its arguments
---@param input string|nil stdin data
---@param pipeline table|nil what the trace line shows (tostring)
---@return table result { exitcode, signal, stdout, stderr, cause }
function M.run(argv, input, pipeline)
    input = input or ""
    local mod  = backend.current()
    local caps = mod.capabilities()
    if caps.stdin == false and input ~= "" then
        local label = mod.name
        if caps.strategy then label = label .. "/" .. caps.strategy end
        local msg = "sh: backend " .. label .. " cannot pass input to "
        error(msg .. tostring(argv[1]), 0)
    end
    local opts = {}
    if config.verbose then
        opts.on_stdout = writer("stdout", io.stdout)
        opts.on_stderr = writer("stderr", io.stderr)
    end
    if config.trace then trace(argv, pipeline) end
    local result = mod.run(argv, input, opts)
    if type(result) ~= "table" then
        local msg = "sh.pipe: backend " .. mod.name .. " returned no result"
        error(msg, 0)
    end
    return result
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.stack" ] = function( ... ) local arg = _G.arg;
---
--- sh.stack: a LIFO stack, used by the pushd and popd builtins.
---

local M = {}
M.__index = M

--- Create an empty stack; call as `Stack:new()`.
---@return table stack
function M:new()
    return setmetatable({ _entries = {} }, M)
end

--- Push `value` on top of the stack.
---@param value any
function M:push(value)
    self._entries[#self._entries + 1] = value
end

--- Remove and return the top value, or nil when the stack is empty.
---@return any value
function M:pop()
    local n = #self._entries
    if n == 0 then return nil end
    local value = self._entries[n]
    self._entries[n] = nil
    return value
end

--- The number of values on the stack.
---@return integer
function M:size()
    return #self._entries
end

return M
end
end

do
local _ENV = _ENV
package.preload[ "sh.sys" ] = function( ... ) local arg = _G.arg;
---
--- sh.sys: platform detection, and load_pcall, the guard for library loads.
---
--- load_pcall is how sh.backend loads and probes backends. Libraries detect
--- features by reading optional globals, and sh.install() turns every
--- undefined global into a command function, which they would take for the
--- feature: luaposix reads `jit` and `bit` on Lua 5.1 and 5.2, and then
--- indexes the function `bit`. While load_pcall runs, loading() is true and
--- install()'s hook leaves undefined globals nil.
---

local M = {}

-- The result of M.platform(), computed once.
local platform = nil

-- Calls of load_pcall in progress.
local loads = 0

local function end_load(...)
    loads = loads - 1
    return ...
end

-- pcall(f, ...) with loading() true while f runs.
local function load_pcall(f, ...)
    loads = loads + 1
    return end_load(pcall(f, ...))
end

--- The platform: "windows", "android" or "posix".
---@return string
function M.platform()
    if platform then return platform end
    local jit = rawget(_G, "jit")
    if package.config:sub(1, 1) == "\\" then
        platform = "windows"
    elseif type(jit) == "table" and jit.os == "Windows" then
        platform = "windows"
    elseif os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA") then
        platform = "android"
    else
        platform = "posix"
    end
    return platform
end

--- pcall(f, ...) for code that loads or probes a library: while f runs,
--- M.loading() is true, and sh.install() leaves undefined globals nil
--- (see the module comment). Returns what pcall returns.
---@param f function
---@return boolean ok
---@return any ... the results of f, or its error
M.load_pcall = load_pcall

--- Whether a load_pcall call is in progress.
---@return boolean
function M.loading()
    return loads > 0
end

return M
end
end

---
--- sh: automatic shell bindings for Lua (LuaSH).
---
---     local sh = require("sh")
---     print(sh.ls("-l"))              -- run a program, print its output
---     print(sh.seq(1, 10):wc("-l"))   -- chain: stdout feeds the next stdin
---     sh.install()                    -- undefined globals become commands
---
--- Every command returns a Result: a table with the fields `__input`,
--- `__stdout`, `__stderr`, `__exitcode`, `__signal` and `__pipeline`.
--- Indexing a Result falls back to this module, which is what makes
--- `r:grep(...)` work. Processes run, and `cd` happens, through the backend
--- that sh.backend selects when this module loads (DESIGN.md sections 3, 4
--- and 6.6).
---

local command_mod = require("sh.command")
local backend     = require("sh.backend")
local pipe        = require("sh.pipe")
local sys         = require("sh.sys")
local Stack       = require("sh.stack")

local unpack    = table.unpack or unpack
local _tostring = tostring
local _print    = print

local Command  = command_mod.Command
local Pipeline = command_mod.Pipeline

---@class sh
local M = {}

M.version = "Automatic Shell Bindings for Lua / LuaSH 2.0.0"

-- The configuration behind sh.config (DESIGN.md section 3.2). verbose,
-- trace, raise_errors and sink are read at every run; backend and popen
-- when this module loads, when a table is assigned to sh.config, and by
-- sh.set_backend(). The module table has no raw `config` field: the
-- metatable maps the name onto this table, so that an assignment reaches
-- newindex_module, which hands the new table to the run path and selects
-- the backend it names.
local settings = {
    verbose      = false,   -- stream child output live
    trace        = false,   -- print "+ <pipeline>" to stderr before each run
    raise_errors = true,    -- error() when a command fails
    backend      = "auto",  -- "auto" | "posix" | "luv" | "popen"
    popen        = {        -- options of the popen backend
        strategy = "auto",  -- or "shmem", "standard", "basic", "minimal"
        tmpdir   = nil,     -- root for temp files; nil = platform default
    },
    sink         = nil,     -- function(stream, chunk) replacing io writes
}

-- `sh.__verbose` and `sh.__raise_errors` read and write these fields of
-- sh.config.
local ALIASES = {
    __verbose      = "verbose",
    __raise_errors = "raise_errors",
}

-- The fields of every Result.
local RESULT_FIELDS = {
    __input  = true, __stdout   = true, __stderr   = true,
    __signal = true, __exitcode = true, __pipeline = true,
}

-- Make `config` the configuration: the backend it names is selected, and
-- the run path reads it from now on. Raises when that backend is
-- unavailable, and sh.config is then unchanged.
local function apply_config(config)
    if type(config) ~= "table" then
        error("sh.config must be a table, not a " .. type(config), 3)
    end
    backend.select(config.backend, config.popen)
    pipe.set_config(config)
    settings = config
end

-- The popen options of sh.config, with those of `opts` on top.
local function popen_options(opts)
    local popen  = type(settings.popen) == "table" and settings.popen or {}
    local chosen = { strategy = popen.strategy, tmpdir = popen.tmpdir }
    for key, value in pairs(opts) do
        chosen[key] = value
    end
    return chosen
end

--------------------------------------------------------------------------------
-- Result objects (DESIGN.md section 3.5)
--------------------------------------------------------------------------------

local function strip(str)
    return str:match("^%s*(.-)%s*$")
end

-- The text of a Result: trimmed stdout, or stdout, stderr and the exit code
-- when there is stderr.
local function result_tostring(self)
    local out = strip(self.__stdout)
    local err = strip(self.__stderr)
    if #err == 0 then return out end
    return "O: " .. out .. "\nE: " .. err .. "\n" .. _tostring(self.__exitcode)
end

-- One operand of `..` with a Result on the other side.
local function concat_text(x)
    local kind = type(x)
    if kind == "string" then return x end
    if kind == "number" then return _tostring(x) end
    if kind == "table" and type(rawget(x, "__stdout")) == "string" then
        return result_tostring(x)
    end
    error("attempt to concatenate a " .. kind .. " value", 3)
end

local function result_concat(lhs, rhs)
    return concat_text(lhs) .. concat_text(rhs)
end

-- A missing Result field is nil (only `__pipeline` can be missing);
-- anything else is looked up in the module.
local function result_index(_, key)
    if RESULT_FIELDS[key] then return nil end
    return M[key]
end

local result_mt = {
    __index    = result_index,
    __tostring = result_tostring,
    __concat   = result_concat,
}

-- A Result from `fields` (the `__` fields; missing ones default to "" or
-- 0) and the Pipeline that produced it, which may be nil.
local function make_result(fields, pipeline)
    local result = {
        __input    = fields.__input or "",
        __stdout   = fields.__stdout or "",
        __stderr   = fields.__stderr or "",
        __exitcode = fields.__exitcode or 0,
        __signal   = fields.__signal or 0,
        __pipeline = pipeline,
    }
    return setmetatable(result, result_mt)
end

--------------------------------------------------------------------------------
-- Running commands
--------------------------------------------------------------------------------

-- The Pipeline a Result records for a run of `cmd` as `argv`, the vector
-- from cmd:argv() that the backend gets: with one source, its stages
-- followed by the Command; otherwise the Command alone, which renders
-- `sources` as a group (`{ a; b; } | cmd`).
--
-- That Command is a new one holding `argv`, so the Result shows what ran,
-- and changing `cmd` after the run does not change it. It is built the way
-- sh.command builds one, with the metatable of `cmd`: nothing is checked
-- or parsed again, so it fails nowhere the run would not. It has no stdin,
-- which is never rendered, and sources only where they are rendered, so a
-- chain `r = r:cat()` does not keep every earlier input and Pipeline alive.
local function provenance(cmd, argv, sources)
    local args = {}
    for i = 2, #argv do
        args[i - 1] = argv[i]
    end
    local fields = { name = argv[1], args = args, stdin = "", sources = {} }
    local snap   = setmetatable(fields, getmetatable(cmd))
    local src    = sources[1]
    local stage  = command_mod.is_pipeline(src) or command_mod.is_command(src)
    if #sources == 1 and stage then return Pipeline(src, snap) end
    for i = 1, #sources do
        snap.sources[i] = sources[i]
    end
    return Pipeline(snap)
end

-- The message to raise for a failed run, or nil when it succeeded
-- (DESIGN.md section 3.6).
local function failure(result, cause, pipeline)
    local killed = cause == "killed" or result.__signal ~= 0
    if result.__exitcode == 0 and not killed then return nil end
    local err = strip(result.__stderr)
    if err ~= "" then return err end
    local where = _tostring(pipeline)
    if killed then
        return where .. ": killed by signal " .. _tostring(result.__signal)
    end
    return where .. ": exit status " .. _tostring(result.__exitcode)
end

-- Run `cmd` with `stdin`, recording `sources` as the provenance of that
-- input. Returns the Result and, when config.raise_errors is set and the
-- run failed, the message to raise.
local function execute(cmd, stdin, sources)
    local argv     = cmd:argv()
    local pipeline = provenance(cmd, argv, sources)
    local res      = pipe.run(argv, stdin, pipeline)
    local fields   = {
        __input  = res.stdout, __stdout   = res.stdout,
        __stderr = res.stderr, __exitcode = res.exitcode,
        __signal = res.signal,
    }
    local result = make_result(fields, pipeline)
    if not settings.raise_errors then return result, nil end
    return result, failure(result, res.cause, pipeline)
end

-- The runner behind Command:run() and Pipeline:run(). `input` is nil for a
-- Command run on its own, or the Result of the previous stage.
local function runner(cmd, input)
    local stdin   = cmd.stdin or ""
    local sources = cmd.sources or {}
    if type(input) == "table" then
        stdin   = input.__input or ""
        sources = { rawget(input, "__pipeline") }
    elseif type(input) == "string" then
        stdin   = input
        sources = {}
    end
    local result, msg = execute(cmd, stdin, sources)
    if msg then error(msg, 2) end
    return result
end

command_mod.set_runner(runner)

-- f(...) for a function of sh.command that checks its arguments, with an
-- argument error raised again at the caller of the function that called
-- checked(), which must not tail-call it. Called through pcall, sh.command
-- puts no position in front of the message, because the level it raises
-- at is pcall itself. A non-string error value passes unchanged: LuaJIT's
-- error() would put a position in front of a number too.
local function checked(f, ...)
    local ok, value = pcall(f, ...)
    if ok then return value end
    if type(value) ~= "string" then error(value, 0) end
    error(value, 3)
end

--- Return a function that runs program `name` with the arguments `...`
--- followed by those of each call, and returns its Result.
---@param name string the program
---@param ... any arguments placed before those of each call
---@return fun(...): table
local function command(name, ...)
    local npre    = select("#", ...)
    local preargs = { ... }
    return function(...)
        local cmd = checked(Command, name, unpack(preargs, 1, npre))
        checked(cmd.arg, cmd, ...)
        local result, msg = execute(cmd, cmd.stdin, cmd.sources)
        if msg then error(msg, 2) end
        return result
    end
end

--------------------------------------------------------------------------------
-- Builtins
--------------------------------------------------------------------------------

-- The Result of a builtin: the fields of the Results it received, passed
-- through, with the Pipeline of the last of them.
local function passthrough(parsed)
    local fields = {
        __input    = parsed.input,
        __stdout   = parsed.fields.__stdout,
        __stderr   = parsed.fields.__stderr,
        __exitcode = parsed.fields.__exitcode,
        __signal   = parsed.fields.__signal,
    }
    return make_result(fields, parsed.sources[#parsed.sources])
end

-- `result` reporting the failure `message` of a builtin.
local function fail(result, message)
    result.__stderr   = message
    result.__exitcode = 1
    return result
end

local function missing(builtin, dir)
    return builtin .. ": The directory '" .. _tostring(dir) .. "' does not exist"
end

local function cd(...)
    local parsed = checked(command_mod.parse, ...)
    local dir    = parsed.args[1]
    local result = passthrough(parsed)
    if not backend.chdir(dir) then
        return fail(result, missing("cd", dir))
    end
    return result
end

local function stdout(t)
    return t.__stdout
end

local function stderr(t)
    return t.__stderr
end

M.PUSHD_STACK = Stack:new()

local function pushd(...)
    local parsed = checked(command_mod.parse, ...)
    local dir    = parsed.args[1]
    local result = passthrough(parsed)
    local old    = backend.getcwd()
    if not old then
        return fail(result, "pushd: cannot read the current directory")
    end
    if not backend.chdir(dir) then
        return fail(result, missing("pushd", dir))
    end
    M.PUSHD_STACK:push(old)
    return result
end

local function popd(...)
    local parsed = checked(command_mod.parse, ...)
    local result = passthrough(parsed)
    local dir    = M.PUSHD_STACK:pop()
    if dir == nil then return fail(result, missing("popd", "EMPTY")) end
    if not backend.chdir(dir) then return fail(result, missing("popd", dir)) end
    return result
end

local function print(...)
    local result = passthrough(checked(command_mod.parse, ...))
    _print(result_tostring(result))
    return result
end

--- The builtins, consulted for the names in __index_ignore_function.
M.FUNCTIONS = {
    cd    = cd,    stdout = stdout, stderr = stderr,
    pushd = pushd, popd   = popd,   print  = print,
}

--------------------------------------------------------------------------------
-- install()
--------------------------------------------------------------------------------

M.__index_ignore_prefix   = { "_G", "_PROMPT" }
M.__index_ignore_exact    = {}
M.__index_ignore_function = {
    "cd", "pushd", "popd", "stdout", "stderr", "print",
}

local function strcmp(a, b)
    return a == b
end

local function prefcmp(a, b)
    return a == b:sub(1, #a)
end

local function list_contains(list, name, comp)
    for _, item in pairs(list) do
        if comp(item, name) then return true end
    end
    return false
end

--- Make undefined globals run the program of the same name: after
--- `sh.install()`, `ls("-l")` is `sh.ls("-l")`. Libraries detect features
--- by reading optional globals (luaposix reads `jit` and `bit` on Lua 5.1
--- and 5.2), so the backends and their libraries are loaded first, and
--- code run by sh.sys.load_pcall, such as a backend loading later, still
--- sees undefined globals as nil.
local function install()
    backend.preload()
    local gmt = getmetatable(_G)
    if gmt == nil then
        gmt = {}
        setmetatable(_G, gmt)
    end
    gmt.__index = function(t, name)
        if type(name) ~= "string" or sys.loading() then
            return rawget(t, name)
        end
        if list_contains(M.__index_ignore_prefix, name, prefcmp) then
            return rawget(t, name)
        end
        if list_contains(M.__index_ignore_exact, name, strcmp) then
            return rawget(t, name)
        end
        if list_contains(M.__index_ignore_function, name, strcmp) then
            return M.FUNCTIONS[name]
        end
        return command(name)
    end
end

--------------------------------------------------------------------------------
-- Module interface
--------------------------------------------------------------------------------

M.command  = command
M.install  = install
M.Command  = Command
M.Pipeline = Pipeline

--- Select the backend in use now: "auto", "posix", "luv", "popen" or a
--- table that implements the backend contract (DESIGN.md section 4);
--- without an argument, the one sh.config.backend names. `opts` are the
--- popen options, on top of sh.config.popen. Raises when the backend is
--- unavailable, and then changes nothing. sh.config records the selection.
---@param choice string|table|nil
---@param opts table|nil for popen: { strategy = ..., tmpdir = ... }
function M.set_backend(choice, opts)
    -- Anything but a table is ignored: on Lua 5.4 and newer
    -- `set_backend(require("x"))` passes the module's file name as `opts`.
    if type(opts) ~= "table" then opts = {} end
    if choice == nil then choice = settings.backend end
    local chosen = popen_options(opts)
    backend.select(choice, chosen)
    if type(settings.popen) ~= "table" then settings.popen = {} end
    settings.popen.strategy = chosen.strategy
    settings.popen.tmpdir   = chosen.tmpdir
    settings.backend        = (choice == nil) and "auto" or choice
end

--- The name of the backend in use; raises when none is available.
---@return string
function M.backend_name()
    return backend.name()
end

--- The available backends, in the order of preference of this platform.
---@return string[]
function M.available_backends()
    return backend.available()
end

--- The capability table of the backend in use (DESIGN.md section 5).
---@return table
function M.capabilities()
    return backend.capabilities()
end

local function index_module(_, name)
    if name == "config" then return settings end
    local alias = ALIASES[name]
    if alias then return settings[alias] end
    if type(name) ~= "string" then return nil end
    if list_contains(M.__index_ignore_function, name, strcmp) then
        return M.FUNCTIONS[name]
    end
    return command(name)
end

local function newindex_module(t, name, value)
    if name == "config" then
        apply_config(value)
        return
    end
    local alias = ALIASES[name]
    if alias then
        settings[alias] = value
        return
    end
    rawset(t, name, value)
end

setmetatable(M, {
    __call     = function(_, name, ...) return command(name, ...) end,
    __index    = index_module,
    __newindex = newindex_module,
})

-- The default backend: the one LUASH_BACKEND names, else the first
-- available one of this platform. Where none is available this module
-- still loads, and the first command raises the reason (sh.backend).
pipe.set_config(settings)
pcall(backend.select, settings.backend, settings.popen)

return M
