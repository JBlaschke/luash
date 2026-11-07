---
--- sh - Automatic shell bindings for Lua.
---
--- Usage:
---   local sh = require("sh")
---   sh.install()          -- wire into _G so bare names become commands
---   print(ls("-la"))
---
---   -- or without install():
---   local result = sh.git("status")
---   print(result)
---
local posix   = require("posix")   -- still needed for cd/pushd/popd (chdir)
local Stack   = require("sh.stack")
local pipe    = require("sh.pipe")   -- backend dispatcher
local argutil = require("sh.args")

local flatten = argutil.flatten
local strip   = argutil.strip
local _tostring = tostring
local _print    = print            -- keep the real print before we shadow it

---@class sh
local M = {}

M.version = "LuaSH 2.0.0"

--- Configurable behaviour (replaces the old M.__verbose / M.__raise_errors).
M.config = {
    verbose      = false,
    raise_errors = true,
}

---------------------------------------------------------------------------
-- Result objects
---------------------------------------------------------------------------

local result_mt  -- forward declaration

local function result_tostring(self)
    local out = strip(self.__stdout)
    local err = strip(self.__stderr)
    if #err == 0 then return out end
    return "O: " .. out .. "\nE: " .. err .. "\n" .. self.__exitcode
end

local function result_concat(lhs, rhs)
    local out, err = lhs, ""
    if type(out) ~= "string" then
        out = strip(lhs.__stdout)
        err = strip(lhs.__stderr)
    end
    if #err ~= 0 then
        out = "O: " .. out .. "\nE: " .. err .. "\n" .. lhs.__exitcode
    end
    return out .. (type(rhs) == "string" and rhs or result_tostring(rhs))
end

result_mt = {
    __tostring = result_tostring,
    __concat   = result_concat,
    __index    = function(_, k) return M[k] end,
}

--- Build a result table from a plain fields table.
--- Fields: input, stdout, stderr, exitcode, signal
local function make_result(f)
    return setmetatable({
        __input    = f.input    or "",
        __stdout   = f.stdout   or "",
        __stderr   = f.stderr   or "",
        __exitcode = f.exitcode,
        __signal   = f.signal   or 0,
    }, result_mt)
end

--- Helper: pass pipeline state through from a flatten() result.
local function passthrough_fields(parsed)
    return {
        input    = parsed.input,
        stdout   = parsed.stdout,
        stderr   = parsed.stderr,
        exitcode = parsed.exitcode,
        signal   = parsed.signal,
    }
end

---------------------------------------------------------------------------
-- command()  –  the core factory
---------------------------------------------------------------------------

--- Return a callable that executes `cmd` (with optional pre-baked args).
---@param cmd string
---@return fun(...): table
local function command(cmd, ...)
    local preargs = { ... }
    return function(...)
        local parsed   = flatten({ ... })
        local all_args = {}
        for _, x in ipairs(preargs)     do all_args[#all_args + 1] = _tostring(x) end
        for _, x in ipairs(parsed.args) do all_args[#all_args + 1] = _tostring(x) end

        local status, cause, stdout, stderr =
            pipe.pipe_simple(parsed.input, cmd, all_args, M.config.verbose)

        if M.config.raise_errors and status ~= 0 then
            error(stderr)
        end

        return make_result({
            input    = stdout,   -- pipe stdout forward as next stage's input
            stdout   = stdout,
            stderr   = stderr,
            exitcode = (cause == "exited")  and status or 127,
            signal   = (cause == "killed")  and status or 0,
        })
    end
end

---------------------------------------------------------------------------
-- Built-in shell functions
---------------------------------------------------------------------------

local builtins = {}

function builtins.cd(...)
    local parsed = flatten({ ... })
    local dir    = parsed.args[1]
    local ok     = posix.chdir(dir)
    local fields = passthrough_fields(parsed)
    if not ok then
        fields.stderr   = "cd: The directory '" .. dir .. "' does not exist"
        fields.exitcode = 1
    end
    return make_result(fields)
end

local pushd_stack = Stack:new()

function builtins.pushd(...)
    local parsed  = flatten({ ... })
    local dir     = parsed.args[1]
    local old_dir = strip(M.pwd().__stdout)
    local ok      = posix.chdir(dir)
    if ok then pushd_stack:push(old_dir) end

    local fields = passthrough_fields(parsed)
    if not ok then
        fields.stderr   = "pushd: The directory '" .. dir .. "' does not exist"
        fields.exitcode = 1
    end
    return make_result(fields)
end

function builtins.popd(...)
    local parsed = flatten({ ... })
    local dir    = pushd_stack:pop()
    local ok
    if dir then
        ok = posix.chdir(dir)
    else
        ok  = nil
        dir = "EMPTY"
    end

    local fields = passthrough_fields(parsed)
    if not ok then
        fields.stderr   = "popd: The directory '" .. dir .. "' does not exist"
        fields.exitcode = 1
    end
    return make_result(fields)
end

function builtins.stdout(t) return t.__stdout end
function builtins.stderr(t) return t.__stderr end

function builtins.print(...)
    local parsed = flatten({ ... })
    local result = make_result(passthrough_fields(parsed))
    _print(result_tostring(result))
    return result
end

---------------------------------------------------------------------------
-- Global install()  –  wire undefined globals to command()
---------------------------------------------------------------------------

local ignore_prefix = { "_G", "_PROMPT" }
local ignore_exact  = {}

local function str_eq(a, b)     return a == b end
local function str_prefix(a, b) return a == b:sub(1, #a) end

local function list_match(list, value, cmp)
    for _, item in ipairs(list) do
        if cmp(item, value) then return true end
    end
    return false
end

function M.install()
    local gmt = getmetatable(_G) or {}
    setmetatable(_G, gmt)

    gmt.__index = function(t, name)
        if list_match(ignore_prefix, name, str_prefix) then return rawget(t, name) end
        if list_match(ignore_exact,  name, str_eq)     then return rawget(t, name) end
        if builtins[name] then return builtins[name] end
        return command(name)
    end
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------

M.command            = command
M.set_backend        = pipe.set_backend
M.backend_name       = pipe.backend_name
M.available_backends = pipe.available_backends

setmetatable(M, {
    --- sh("git", "status")  =>  command("git", "status")
    __call = function(_, cmd, ...)
        return command(cmd, ...)
    end,
    --- sh.git  =>  command("git")   (or a builtin if one matches)
    __index = function(_, name)
        if builtins[name] then return builtins[name] end
        return command(name)
    end,
})

return M
