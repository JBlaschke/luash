#!/usr/bin/env lua

--------------------------------------------------------------------------------
-- Build standalone/sh.lua, the single-file LuaSH library.
--
-- Amalgamates sh/init.lua (the main script) with every other module under
-- sh/, so that a user can copy one file into a project and load it with
-- require("sh"). Run it as `make standalone`, or as `lua opt/bin/build.lua`
-- from any directory. It needs only the Lua standard library and a POSIX
-- shell with `find`, and runs on Lua 5.1 to 5.5 and LuaJIT.
--
-- The module list comes from scanning sh/, so a new module cannot be left
-- out: sh/x.lua is embedded as sh.x and sh/backend/y.lua as sh.backend.y.
-- posix and luv are never embedded. They are C modules that the library
-- loads from the host at run time, inside pcall, and the scan only yields
-- names under sh.
--------------------------------------------------------------------------------

local unpack = table.unpack or unpack

--- Print a progress message. Flushed, so that it stays in order with the
--- error messages on stderr.
local function say(...)
    io.stdout:write("build.lua: ", ...)
    io.stdout:write("\n")
    io.stdout:flush()
end

--- Print an error message and exit with status 1.
---@param message string
local function fail(message)
    io.stderr:write("build.lua: ", message, "\n")
    os.exit(1)
end

--- Quote a string as one word for a POSIX shell.
---@param s string
---@return string
local function shell_quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

--- Run a shell command and return its output without the final newline.
--- The exit status is not checked (LuaJIT does not report it); callers
--- validate the output instead.
---@param cmd string
---@return string
local function capture(cmd)
    local h   = assert(io.popen(cmd, "r"))
    local out = h:read("*a")
    h:close()
    return (out:gsub("\n$", ""))
end

--- Return the absolute path of the repository root, two directories above
--- the directory that holds this script.
---@return string
local function find_root()
    local script = arg and arg[0]
    if not script then
        script = debug.getinfo(1, "S").source:match("^@(.*)$")
    end
    if not script then fail("cannot tell where this script is") end
    local dir = script:match("^(.*)/[^/]*$") or "."
    -- A relative path that starts with "./" is never looked up in CDPATH,
    -- whose matches `cd` would echo into the captured output.
    if dir:sub(1, 1) ~= "/" then dir = "./" .. dir end
    local root = capture("cd " .. shell_quote(dir .. "/../..") .. " && pwd")
    if root:sub(1, 1) ~= "/" then
        fail("cannot find the repository root from " .. script)
    end
    return root
end

--- List the modules under <root>/sh/ that are embedded next to the main
--- script sh/init.lua, sorted by name. Each file must compile, so that a
--- syntax error is reported against its own file and line.
---@param root string
---@return string[]
local function scan_modules(root)
    local listing = capture(
        "cd " .. shell_quote(root) .. " && find sh -name '*.lua' -type f"
    )
    local modules  = {}
    local has_main = false
    for file in listing:gmatch("[^\n]+") do
        if ("/" .. file):find("/%.") then
            say("skipping hidden file ", file)
        else
            local chunk, err = loadfile(root .. "/" .. file)
            if not chunk then fail(err) end
            local name = file:gsub("%.lua$", ""):gsub("/", ".")
            -- sh/x/init.lua is what require("sh.x") finds through ?/init.lua
            name = name:gsub("%.init$", "")
            if name == "sh" then
                has_main = true
            else
                modules[#modules + 1] = name
            end
        end
    end
    if not has_main then fail(root .. "/sh/init.lua not found") end
    table.sort(modules)
    return modules
end

local root    = find_root()
local modules = scan_modules(root)
local main    = root .. "/sh/init.lua"
local output  = root .. "/standalone/sh.lua"
-- amalg writes its output while it reads the modules; writing to a
-- temporary name and renaming at the end never leaves a truncated library.
local partial = output .. ".tmp"

-- amalg finds each module on package.path, as require would.
package.path = root .. "/?.lua;" .. root .. "/?/init.lua"

local made = os.execute("mkdir -p " .. shell_quote(root .. "/standalone"))
if not (made == true or made == 0) then
    fail("cannot create " .. root .. "/standalone")
end

-- Load the vendored amalg.lua as a function in its own environment that
-- inherits _G, so that its globals, if any, stay out of ours. Lua 5.1
-- ignores the mode and env arguments of loadfile; setfenv covers it.
local amalg_path = root .. "/opt/bin/build/amalg.lua"
local env        = setmetatable({}, { __index = _G })
local amalg, err = loadfile(amalg_path, "t", env)
if not amalg then fail(err) end
if setfenv then setfenv(amalg, env) end

say("embedding ", table.concat(modules, ", "))

local ok, amalg_err = pcall(amalg, "-o", partial, "-s", main, unpack(modules))
if not ok then
    os.remove(partial)
    fail("amalg failed: " .. tostring(amalg_err))
end

-- The generated file must at least compile on the interpreter that built it.
local chunk, load_err = loadfile(partial)
if not chunk then
    os.remove(partial)
    fail("generated file does not load: " .. load_err)
end

local renamed, rename_err = os.rename(partial, output)
if not renamed then fail(rename_err) end
say("wrote ", output)
