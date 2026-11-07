---
--- sh.pipe: the backend dispatcher (DESIGN.md section 6.4).
---
--- It picks a process backend (sh/backend/<name>.lua, contract in DESIGN.md
--- section 4) by platform, loads it lazily with pcall so that `require("sh")`
--- works when a backend or its C module is missing, and owns the verbose and
--- trace plumbing. It reads the configuration table that sh/init.lua hands
--- over with set_config(), and never requires sh.init.
---
--- Resolution: config.backend names a backend, holds a backend table, or is
--- "auto". For "auto", LUASH_BACKEND names the backend when set; otherwise
--- the first available backend in ORDER[platform] is used. The popen
--- options come from config.popen; LUASH_POPEN_STRATEGY replaces a strategy
--- of "auto". Both variables are read once, at first use. A change of
--- config.backend or config.popen takes effect at the next run.
---
--- Each candidate is configured with those options before it is asked
--- whether it is available, because popen answers for its configured
--- strategy. Availability is asked again at every resolution.
---

local sys = require("sh.sys")

local M = {}

local ORDER = {
    posix   = { "posix", "luv", "popen" },
    windows = { "luv", "popen" },
    android = { "luv", "posix", "popen" },
}

--- Backend preference by platform, see sys.platform().
M.ORDER = ORDER

-- The configuration in use until init.lua calls set_config.
local config = {
    verbose      = false,
    trace        = false,
    raise_errors = true,
    backend      = "auto",
    popen        = { strategy = "auto" },
}

-- LUASH_BACKEND and LUASH_POPEN_STRATEGY, read once.
local env = nil

-- The backend in use and the key of the configuration it was resolved for.
local active     = nil
local active_key = nil

local function getenv(name)
    local value = os.getenv(name)
    if value == nil or value == "" or value == "auto" then return nil end
    return value
end

local function environment()
    if env == nil then
        env = {
            backend  = getenv("LUASH_BACKEND"),
            strategy = getenv("LUASH_POPEN_STRATEGY"),
        }
    end
    return env
end

-- The first line of an error value, without a trailing colon, for messages
-- naming a reason.
local function first_line(err)
    local line = tostring(err):match("^([^\n]*)")
    return (line:gsub(":%s*$", ""))
end

-- The module of backend `name`, or nil and the reason it does not load.
-- require remembers only a success, so a backend installed later in the
-- process is found on the next try.
local function load(name)
    local ok, mod = pcall(require, "sh.backend." .. name)
    if not ok then return nil, first_line(mod) end
    if type(mod) ~= "table" or type(mod.run) ~= "function" then
        return nil, "sh.backend." .. name .. " is not a backend"
    end
    return mod
end

-- Configure `mod` with `opts`, then ask whether it is available: true, or
-- false and the reason. A configure() that raises (popen: an unknown
-- strategy) makes the backend unavailable for that reason.
local function ready(mod, opts)
    if type(mod.configure) == "function" then
        local ok, err = pcall(mod.configure, opts)
        if not ok then return false, first_line(err) end
    end
    if type(mod.available) ~= "function" then return true end
    local called, avail, why = pcall(mod.available)
    if called and avail then return true end
    return false, first_line(why or avail or "not available")
end

-- The backend `name`, configured with `opts`, when it loads and is
-- available; otherwise nil and the reason.
local function candidate(name, opts)
    local mod, why = load(name)
    if not mod then return nil, why end
    local ok, reason = ready(mod, opts)
    if not ok then return nil, reason end
    return mod
end

local function unavailable(name, why)
    error("sh.pipe: backend " .. name .. " is unavailable: " .. why, 0)
end

-- The backend for `choice`, a name, "auto" or a backend table, configured
-- with `opts`. Raises when it is not available.
local function select_backend(choice, opts)
    if type(choice) == "table" then
        if type(choice.name) ~= "string" or type(choice.run) ~= "function" then
            error("sh.pipe: a backend table needs a name and a run function", 0)
        end
        local ok, why = ready(choice, opts)
        if not ok then unavailable(choice.name, why) end
        return choice
    end
    if choice == nil or choice == "auto" then
        choice = environment().backend or "auto"
    end
    if type(choice) ~= "string" then
        local kind = type(choice)
        error("sh.pipe: a backend is a name or a table, not a " .. kind, 0)
    end
    if choice ~= "auto" then
        local mod, why = candidate(choice, opts)
        if not mod then unavailable(choice, why) end
        return mod
    end
    local platform = sys.platform()
    local tried    = {}
    for _, name in ipairs(ORDER[platform] or ORDER.posix) do
        local mod, why = candidate(name, opts)
        if mod then return mod end
        tried[#tried + 1] = name .. " (" .. why .. ")"
    end
    local msg = "sh.pipe: no backend available on " .. platform .. ": "
    error(msg .. table.concat(tried, "; "), 0)
end

-- The options passed to a backend's configure(): those of `popen` (the
-- shape of config.popen), with LUASH_POPEN_STRATEGY for a strategy of
-- "auto".
local function backend_options(popen)
    popen = type(popen) == "table" and popen or {}
    local strategy = popen.strategy
    if strategy == nil or strategy == "auto" then
        strategy = environment().strategy or "auto"
    end
    return { strategy = strategy, tmpdir = popen.tmpdir }
end

-- Identifies the configuration a backend was resolved for.
local function config_key()
    local popen = type(config.popen) == "table" and config.popen or {}
    return table.concat({
        tostring(config.backend), tostring(popen.strategy),
        tostring(popen.tmpdir),
    }, "\0")
end

-- The backend in use, resolved again when the configuration changed.
local function current()
    local key = config_key()
    if active and key == active_key then return active end
    active = nil  -- a selection that raises may have reconfigured it
    local mod = select_backend(config.backend, backend_options(config.popen))
    active     = mod
    active_key = key
    return mod
end

local function capabilities_of(mod)
    if type(mod.capabilities) ~= "function" then return { name = mod.name } end
    return mod.capabilities() or { name = mod.name }
end

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

--- Select a backend now and record it in the configuration. Raises when it
--- is unavailable.
---@param backend string|table "auto", a backend name or a backend table
---@param opts table|nil for popen: { strategy = ..., tmpdir = ... }
function M.set_backend(backend, opts)
    -- Anything but a table is ignored: on Lua 5.4 and newer
    -- `set_backend(require("x"))` passes the module's file name as `opts`.
    if type(opts) ~= "table" then opts = {} end
    local popen  = type(config.popen) == "table" and config.popen or {}
    local chosen = { strategy = popen.strategy, tmpdir = popen.tmpdir }
    if opts.strategy ~= nil then chosen.strategy = opts.strategy end
    if opts.tmpdir ~= nil then chosen.tmpdir = opts.tmpdir end
    local merged = backend_options(chosen)
    for k, v in pairs(opts) do
        if merged[k] == nil then merged[k] = v end
    end
    -- The selection may reconfigure the backend in use; when it raises, the
    -- next run resolves the backend again from the configuration.
    active = nil
    local mod = select_backend(backend, merged)

    if type(config.popen) ~= "table" then config.popen = {} end
    config.popen.strategy = chosen.strategy
    config.popen.tmpdir   = chosen.tmpdir
    config.backend        = (backend == nil) and "auto" or backend

    active     = mod
    active_key = config_key()
end

--- The name of the backend in use; resolves "auto". Raises when no backend
--- is available.
---@return string
function M.backend_name()
    return current().name
end

--- The names of the available backends, in the order of this platform.
---@return string[]
function M.available_backends()
    local opts  = backend_options(config.popen)
    local names = {}
    -- The backend in use keeps the options it was selected with; one
    -- selected for an older configuration is reconfigured below and
    -- resolved again at the next run.
    if active_key ~= config_key() then active = nil end
    for _, name in ipairs(ORDER[sys.platform()] or ORDER.posix) do
        local mod = load(name)
        local ok  = false
        if mod then ok = (mod == active) or ready(mod, opts) end
        if ok then names[#names + 1] = name end
    end
    return names
end

--- The capability table of the backend in use (DESIGN.md section 5).
---@return table
function M.capabilities()
    return capabilities_of(current())
end

--- Run `argv` with `input` on stdin through the backend in use and return
--- the backend's result table. Streams output when config.verbose is set,
--- writes the trace line when config.trace is set, and runs in the emulated
--- working directory when sh.sys emulates `cd`.
---@param argv string[] the program and its arguments
---@param input string|nil stdin data
---@param pipeline table|nil what the trace line shows (tostring)
---@return table result { exitcode, signal, stdout, stderr, cause }
function M.run(argv, input, pipeline)
    input = input or ""
    local mod  = current()
    local caps = capabilities_of(mod)
    if caps.stdin == false and input ~= "" then
        local label = mod.name
        if caps.strategy then label = label .. "/" .. caps.strategy end
        local msg = "sh: backend " .. label .. " cannot pass input to "
        error(msg .. tostring(argv[1]), 0)
    end
    local opts = { cwd = sys.emulated_cwd() }
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
