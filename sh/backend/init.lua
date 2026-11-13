---
--- sh.backend: the backend registry (DESIGN.md section 6.6).
---
--- A backend is a module sh/backend/<name>.lua that implements the contract
--- of DESIGN.md section 4: it runs programs and owns the working directory
--- and the environment. The registry selects one backend, configures it,
--- and keeps it as the backend in use until select() is called again;
--- nothing about a backend is probed at a run or a cd. sh/init.lua selects
--- the default when it loads, and sh.set_backend() selects another one.
--- run, chdir, getcwd, setenv, getenv and capabilities go to the backend
--- in use: the frontend sees one interface. setenv and getenv are not
--- part of the contract: a backend without setenv cannot change the
--- environment, and setenv() here says so.
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

--- Set variable `name` to `value` for the programs that the backend in use
--- runs, or remove it for them when `value` is nil. posix and luv change
--- the environment of the process; popen remembers the change for its
--- runs. A backend without setenv() cannot do either.
---@param name string not empty, without "=" and NUL bytes
---@param value string|nil without NUL bytes
---@return true|nil ok
---@return string|nil err
function M.setenv(name, value)
    local named = type(name) == "string" and name ~= ""
    if not named or name:find("[=%z]") then
        return nil, "sh.backend.setenv: expected a variable name"
    end
    if value ~= nil and (type(value) ~= "string" or value:find("%z")) then
        return nil, "sh.backend.setenv: expected a string or nil as value"
    end
    local mod = M.current()
    if type(mod.setenv) ~= "function" then
        return nil, "backend " .. mod.name .. " cannot change the environment"
    end
    local done, err = mod.setenv(name, value)
    if done then return true end
    return nil, tostring(err or "cannot change the variable")
end

--- The value of variable `name` for the programs that the backend in use
--- runs, nil when it is not set: what the backend's getenv() says, else
--- the environment of the process.
---@param name string
---@return string|nil value
function M.getenv(name)
    local mod = M.current()
    if type(mod.getenv) ~= "function" then return os.getenv(name) end
    return mod.getenv(name)
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
