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
