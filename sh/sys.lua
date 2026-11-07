---
--- sh.sys: platform detection and the working directory, with fallbacks
--- (DESIGN.md section 6.5).
---
--- chdir and getcwd use luaposix when it loads, else luv. With neither, `cd`
--- is emulated: the directory is checked through io.popen and remembered,
--- and the dispatcher passes it to every backend as `opts.cwd`. The
--- emulated directory affects the commands run by `sh` only, not Lua's own
--- io functions. luaposix and luv are only loaded through load_pcall.
---
--- load_pcall is also how sh.pipe loads and probes backends. Libraries
--- detect features by reading optional globals, and sh.install() turns
--- every undefined global into a command function, which they would take
--- for the feature: luaposix reads `jit` and `bit` on Lua 5.1 and 5.2, and
--- then indexes the function `bit`. While load_pcall runs, loading() is
--- true and install()'s hook leaves undefined globals nil.
---

local M = {}

-- Loaded C modules by name; false once a load has failed.
local modules = {}

-- The directory `cd` moved to while emulating, nil before the first `cd`.
local emulated = nil

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

-- The module `name` (posix or luv), or nil when it does not load.
local function load(name)
    if modules[name] == nil then
        local ok, mod = load_pcall(require, name)
        modules[name] = ok and type(mod) == "table" and mod or false
    end
    return modules[name] or nil
end

local function posix_with(field)
    local posix = load("posix")
    if posix and type(posix[field]) == "function" then return posix end
    return nil
end

local function luv_with(field)
    local uv = load("luv")
    if uv and type(uv[field]) == "function" then return uv end
    return nil
end

-- Whether a real chdir is available, so that no emulation is needed.
local function has_chdir()
    return posix_with("chdir") ~= nil or luv_with("chdir") ~= nil
end

-- The first line of the output of shell command `script`, or nil.
local function popen_line(script)
    local ok, h = pcall(io.popen, script, "r")
    if not ok or not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    return out:match("^([^\r\n]+)")
end

-- `s` in single quotes for a POSIX shell, `'` written as `'\''`.
local function sh_quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- The shell command that prints the absolute path of `dir`, taken relative
-- to `base` when given, and prints nothing when `dir` is not a directory
-- one can enter. Windows (cmd.exe) is best effort and untested.
local function resolve_script(base, dir)
    if M.platform() == "windows" then
        local steps = {}
        if base then steps[#steps + 1] = 'cd /d "' .. base .. '"' end
        steps[#steps + 1] = 'cd /d "' .. dir .. '"'
        steps[#steps + 1] = "cd"
        return "(" .. table.concat(steps, " && ") .. ") 2>NUL"
    end
    -- "./" keeps a relative name away from CDPATH and from option parsing
    -- (`cd -` is the previous directory).
    if dir:sub(1, 1) ~= "/" then dir = "./" .. dir end
    local steps = {}
    if base then steps[#steps + 1] = "cd " .. sh_quote(base) end
    steps[#steps + 1] = "cd " .. sh_quote(dir)
    steps[#steps + 1] = "pwd -P"
    return "(" .. table.concat(steps, " && ") .. ") 2>/dev/null"
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

--- Change the working directory: through luaposix, else luv, else by
--- emulation (see the module comment).
---@param dir string
---@return true|nil ok
---@return string|nil err
function M.chdir(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil, "sh.sys.chdir: expected a directory name"
    end
    local posix = posix_with("chdir")
    if posix then
        local ok, err = posix.chdir(dir)
        if ok then return true end
        return nil, err or dir .. ": cannot change directory"
    end
    local uv = luv_with("chdir")
    if uv then
        local ok, err = uv.chdir(dir)
        if ok then return true end
        return nil, dir .. ": " .. (err or "cannot change directory")
    end
    local path = popen_line(resolve_script(emulated, dir))
    if not path then
        return nil, dir .. ": cannot change directory"
    end
    emulated = path
    return true
end

--- The working directory: from luaposix, else luv, else the emulated
--- directory, else `pwd` through io.popen.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    local posix = posix_with("getcwd")
    if posix then return posix.getcwd() end
    local uv = luv_with("cwd")
    if uv then return uv.cwd() end
    if emulated then return emulated end
    local script = (M.platform() == "windows") and "cd" or "pwd -P"
    local path   = popen_line(script)
    if not path then
        return nil, "sh.sys.getcwd: cannot read the working directory"
    end
    return path
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

--- The directory `cd` moved to by emulation, or nil when a real chdir is
--- available or no `cd` has happened yet.
---@return string|nil
function M.emulated_cwd()
    if has_chdir() then return nil end
    return emulated
end

return M
