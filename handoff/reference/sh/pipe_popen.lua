---
--- Process I/O backend using only io.popen / os.execute.
---
--- Backend: pure Lua (no C dependencies beyond the standard library)
---
--- Because io.popen is unidirectional, this module uses configurable
--- *strategies* that trade off portability for capability:
---
---   "minimal"  – No temp files.  Input is discarded (/dev/null).
---                Stderr is merged into stdout (2>&1).
---                Works on anything with a POSIX-ish shell.
---
---   "basic"    – No temp files.  Small inputs are piped via the shell's
---                printf builtin.  Stderr is still merged.
---                Limited by the OS argument-size ceiling (~128 KB–2 MB).
---
---   "standard" – Temp files in the system temp directory provide full
---                stdin/stdout/stderr separation.
---                Requires a writable filesystem.
---
---   "shmem"    – Like "standard" but files are placed in /dev/shm
---                (Linux RAM-backed tmpfs).  Fast; cleaned automatically
---                on reboot even if the process crashes.
---
--- The default strategy is "standard".  Change it via:
---
---   local popen = require("sh.pipe_popen")
---   popen.strategy = "shmem"
---

local M = {}

M.name     = "popen"
M.strategy = "standard"            -- active strategy name

---------------------------------------------------------------------------
-- Temp-file management
---------------------------------------------------------------------------

--- Registry of temp files that haven't been cleaned up yet.  Keyed by path.
--- Used both for per-call cleanup and as a safety net on module unload.
local active_tmpfiles = {}

local _counter = 0

--- Generate a unique temp-file path under `dir`.
--- Falls back to os.tmpname() when dir is nil (system default).
local function make_tmppath(dir)
    _counter = _counter + 1
    if not dir then
        -- os.tmpname() delegates to the C library's tmpnam / mktemp and
        -- guarantees cross-process uniqueness.
        local name = os.tmpname()
        active_tmpfiles[name] = true
        return name
    end
    -- For custom directories (e.g. /dev/shm) we build our own unique name.
    -- Combine: a high-resolution clock sample, a per-process monotonic
    -- counter, and a random component to cover fork()-without-re-seed.
    local name = string.format(
        "%s/sh_lua_%s_%d_%d",
        dir,
        tostring(os.clock()):gsub("[^%d]", ""),
        _counter,
        math.random(100000, 999999)
    )
    active_tmpfiles[name] = true
    return name
end

--- Remove a temp file and un-register it.
local function remove_tmp(path)
    if path and active_tmpfiles[path] then
        os.remove(path)
        active_tmpfiles[path] = nil
    end
end

--- Emergency cleanup: remove every temp file still in the registry.
--- Called automatically if the module is collected, but callers may also
--- invoke it explicitly on shutdown.
function M.cleanup_all()
    for path in pairs(active_tmpfiles) do
        os.remove(path)
    end
    active_tmpfiles = {}
end

---------------------------------------------------------------------------
-- Shell helpers
---------------------------------------------------------------------------

--- Escape a string for embedding inside single-quotes in a POSIX shell.
local function shell_escape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Portable close for io.popen handles.
--- Lua 5.2+ returns (ok, exit_type, code); Lua 5.1 returns only a boolean.
local function close_handle(h)
    local results = { h:close() }
    if type(results[2]) == "string" then
        -- Lua 5.2+
        local exit_type, code = results[2], results[3]
        local cause = (exit_type == "signal") and "killed" or "exited"
        return code, cause
    end
    -- Lua 5.1: no exit code available; 0 is the best we can do.
    return 0, "exited"
end

--- Write `data` to `path` with restrictive permissions.
--- We open-then-write in a single step so no other user can slip a symlink
--- in between name generation and first write.
local function write_file(path, data)
    local f, err = io.open(path, "w")
    if not f then error("pipe_popen: cannot write " .. path .. ": " .. tostring(err)) end
    f:write(data)
    f:close()
    -- Best-effort permission lockdown; may be a no-op on non-POSIX systems.
    os.execute("chmod 600 " .. shell_escape(path) .. " 2>/dev/null")
end

--- Read and return the full contents of `path`, or "" on failure.
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local data = f:read("*a")
    f:close()
    return data or ""
end

---------------------------------------------------------------------------
-- Strategy implementations
--
-- Each returns: exit_status, wait_cause, stdout_string, stderr_string
-- and is responsible for cleaning up any temp files it creates, even when
-- the command itself fails.
---------------------------------------------------------------------------

local strategies = {}

function strategies.minimal(input, cmd, args, verbose)
    -- No temp files.  Input is ignored.  Stderr merges into stdout.
    local shell_args = {}
    for _, a in ipairs(args) do shell_args[#shell_args + 1] = shell_escape(a) end

    local shell_cmd = string.format(
        "%s %s </dev/null 2>&1",
        shell_escape(cmd),
        table.concat(shell_args, " ")
    )

    local h = io.popen(shell_cmd, "r")
    if not h then error("pipe_popen: popen failed for: " .. shell_cmd) end

    local stdout = h:read("*a") or ""
    local code, cause = close_handle(h)

    if verbose and #stdout > 0 then io.write(stdout) end
    return code, cause, stdout, ""
end

function strategies.basic(input, cmd, args, verbose)
    -- Pipe input via printf; no temp files.  Stderr merged into stdout.
    local shell_args = {}
    for _, a in ipairs(args) do shell_args[#shell_args + 1] = shell_escape(a) end

    local shell_cmd
    if not input or #input == 0 then
        shell_cmd = string.format(
            "%s %s </dev/null 2>&1",
            shell_escape(cmd),
            table.concat(shell_args, " ")
        )
    else
        shell_cmd = string.format(
            "printf '%%s' %s | %s %s 2>&1",
            shell_escape(input),
            shell_escape(cmd),
            table.concat(shell_args, " ")
        )
    end

    local h = io.popen(shell_cmd, "r")
    if not h then error("pipe_popen: popen failed for: " .. shell_cmd) end

    local stdout = h:read("*a") or ""
    local code, cause = close_handle(h)

    if verbose and #stdout > 0 then io.write(stdout) end
    return code, cause, stdout, ""
end

--- Shared implementation for "standard" and "shmem" (they differ only in
--- which directory hosts the temp files).
local function strategy_tmpfile(tmpdir, input, cmd, args, verbose)
    local input_path  = (#input > 0) and make_tmppath(tmpdir) or nil
    local stderr_path = make_tmppath(tmpdir)

    -- Wrap the entire execution in pcall so temp files are cleaned up even
    -- if something throws.
    local ok, code_or_err, cause, stdout, stderr = pcall(function()
        if input_path then write_file(input_path, input) end

        local shell_args = {}
        for _, a in ipairs(args) do shell_args[#shell_args + 1] = shell_escape(a) end

        local input_redir = input_path
            and ("< " .. shell_escape(input_path))
            or  "< /dev/null"

        local shell_cmd = string.format(
            "%s %s %s 2>%s",
            shell_escape(cmd),
            table.concat(shell_args, " "),
            input_redir,
            shell_escape(stderr_path)
        )

        local h = io.popen(shell_cmd, "r")
        if not h then error("pipe_popen: popen failed for: " .. shell_cmd) end

        local out = h:read("*a") or ""
        local c, w = close_handle(h)
        local err = read_file(stderr_path)

        if verbose then
            if #out > 0 then io.write(out) end
            if #err > 0 then io.write(err) end
        end

        return c, w, out, err
    end)

    -- Always clean up, whether the pcall succeeded or not.
    remove_tmp(input_path)
    remove_tmp(stderr_path)

    if not ok then error(code_or_err) end
    return code_or_err, cause, stdout, stderr
end

function strategies.standard(input, cmd, args, verbose)
    -- nil => os.tmpname() picks the system temp directory
    return strategy_tmpfile(nil, input, cmd, args, verbose)
end

function strategies.shmem(input, cmd, args, verbose)
    return strategy_tmpfile("/dev/shm", input, cmd, args, verbose)
end

---------------------------------------------------------------------------
-- Strategy availability probes
---------------------------------------------------------------------------

local availability = {}

function availability.minimal()  return true end
function availability.basic()    return true end

function availability.standard()
    -- Verify we can create and remove a temp file.
    local ok, path = pcall(os.tmpname)
    if ok and path then os.remove(path); return true end
    return false
end

function availability.shmem()
    -- /dev/shm must exist and be writable.
    local probe = "/dev/shm/.sh_lua_probe_" .. math.random(100000, 999999)
    local f = io.open(probe, "w")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

--- Return an ordered list of available strategy names.
function M.available_strategies()
    local order  = { "shmem", "standard", "basic", "minimal" }
    local result = {}
    for _, name in ipairs(order) do
        if availability[name]() then
            result[#result + 1] = name
        end
    end
    return result
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Run `cmd` with `args`, feeding `input` on stdin.
--- Returns: exit_status, wait_cause, stdout_string, stderr_string
---
--- @param input   string   Data to write to the child's stdin.
--- @param cmd     string   Program name (resolved via PATH by the shell).
--- @param args    table    Array of string arguments.
--- @param verbose boolean  If true, write output chunks as they arrive.
function M.pipe_simple(input, cmd, args, verbose)
    local strat = strategies[M.strategy]
    if not strat then
        error("pipe_popen: unknown strategy '" .. tostring(M.strategy) .. "'")
    end
    return strat(input or "", cmd, args, verbose)
end

--- Check whether the named strategy (or the active one) is usable on
--- this system.
function M.is_available(name)
    name = name or M.strategy
    local probe = availability[name]
    return probe and probe() or false
end

return M
