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
--- `r:grep(...)` work. Processes run through the backend that sh.pipe
--- selects (DESIGN.md sections 3 and 4).
---

local command_mod = require("sh.command")
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

--- Configuration, read at every run (DESIGN.md section 3.2).
M.config = {
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

-- `sh.__verbose` and `sh.__raise_errors` read and write these config fields.
local ALIASES = {
    __verbose      = "verbose",
    __raise_errors = "raise_errors",
}

-- The fields of every Result.
local RESULT_FIELDS = {
    __input  = true, __stdout   = true, __stderr   = true,
    __signal = true, __exitcode = true, __pipeline = true,
}

-- Hand the current sh.config to the dispatcher; a script may have replaced
-- the whole table.
local function sync_config()
    local config = rawget(M, "config")
    if type(config) == "table" then pipe.set_config(config) end
    return config
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
    local config   = sync_config() or {}
    local argv     = cmd:argv()
    local pipeline = provenance(cmd, argv, sources)
    local res      = pipe.run(argv, stdin, pipeline)
    local fields   = {
        __input  = res.stdout, __stdout   = res.stdout,
        __stderr = res.stderr, __exitcode = res.exitcode,
        __signal = res.signal,
    }
    local result = make_result(fields, pipeline)
    if not config.raise_errors then return result, nil end
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
    if not sys.chdir(dir) then return fail(result, missing("cd", dir)) end
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
    local old    = sys.getcwd()
    if not old then
        return fail(result, "pushd: cannot read the current directory")
    end
    if not sys.chdir(dir) then return fail(result, missing("pushd", dir)) end
    M.PUSHD_STACK:push(old)
    return result
end

local function popd(...)
    local parsed = checked(command_mod.parse, ...)
    local result = passthrough(parsed)
    local dir    = M.PUSHD_STACK:pop()
    if dir == nil then return fail(result, missing("popd", "EMPTY")) end
    if not sys.chdir(dir) then return fail(result, missing("popd", dir)) end
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
    pipe.preload()
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

--- Select a backend now: "auto", "posix", "luv", "popen" or a table that
--- implements the backend contract. Raises when it is unavailable.
---@param backend string|table
---@param opts table|nil for popen: { strategy = ..., tmpdir = ... }
function M.set_backend(backend, opts)
    sync_config()
    return pipe.set_backend(backend, opts)
end

--- The name of the backend in use; raises when none is available.
---@return string
function M.backend_name()
    sync_config()
    return pipe.backend_name()
end

--- The available backends, in the order of preference of this platform.
---@return string[]
function M.available_backends()
    return pipe.available_backends()
end

--- The capability table of the backend in use (DESIGN.md section 5).
---@return table
function M.capabilities()
    sync_config()
    return pipe.capabilities()
end

-- sh.config, replaced by a new table when a script stored something else.
local function config_table()
    local config = rawget(M, "config")
    if type(config) ~= "table" then
        config = {}
        rawset(M, "config", config)
    end
    return config
end

local function index_module(_, name)
    local alias = ALIASES[name]
    if alias then return config_table()[alias] end
    if type(name) ~= "string" then return nil end
    if list_contains(M.__index_ignore_function, name, strcmp) then
        return M.FUNCTIONS[name]
    end
    return command(name)
end

local function newindex_module(t, name, value)
    local alias = ALIASES[name]
    if alias then
        config_table()[alias] = value
        return
    end
    rawset(t, name, value)
end

setmetatable(M, {
    __call     = function(_, name, ...) return command(name, ...) end,
    __index    = index_module,
    __newindex = newindex_module,
})

sync_config()

return M
