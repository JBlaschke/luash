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

-- Record in `vars` that variable `name` is to get `value`: a string or a
-- number, or false for a variable to remove.
local function add_variable(vars, name, value)
    local kind = type(value)
    if name == "" then
        error("sh.command: empty variable name", 0)
    elseif name:find("%z") then
        error("sh.command: a variable name contains a NUL byte", 0)
    elseif name:find("=", 1, true) then
        error("sh.command: the variable name '" .. name .. "' contains =", 0)
    elseif kind == "number" then
        value = _tostring(value)
    elseif value == true then
        local hint = "; give a value, or false to remove it"
        error("sh.command: variable '" .. name .. "' is true" .. hint, 0)
    elseif value ~= false and kind ~= "string" then
        local what = "bad " .. kind .. " value for variable '"
        error("sh.command: " .. what .. name .. "'", 0)
    elseif value and value:find("%z") then
        local what = "the value of variable '" .. name
        error("sh.command: " .. what .. "' contains a NUL byte", 0)
    end
    vars[name] = value
end

local collect  -- forward declaration; it and collect_table call each other

-- Collect from table `t`: its array entries, then its string keys as
-- variable names, in sorted order.
local function collect_table(t, out, active)
    local n = #t
    for i = 1, n do
        collect(t[i], out, active)
    end

    local extra  = {}
    local names  = {}
    local values = {}
    for k, v in pairs(t) do
        local kind = type(k)
        if kind == "number" and k > n and k % 1 == 0 then
            extra[#extra + 1] = k
            values[k]         = v
        elseif kind == "string" then
            names[#names + 1] = k
            values[k]         = v
        end
    end
    table.sort(extra)
    for _, k in ipairs(extra) do
        collect(values[k], out, active)
    end
    table.sort(names, byte_less)
    for _, name in ipairs(names) do
        add_variable(out.vars, name, values[name])
    end
end

-- Add one argument of `pushenv` to `out`: the variables it names go to
-- `out.vars`, and a Result is walked like any argument.
function collect(value, out, active)
    local kind = type(value)
    if value == nil or value == false then
        return
    elseif kind == "string" then
        local name, text = value:match("^([^=]*)=(.*)$")
        if not name then
            error("sh.command: expected NAME=value, got '" .. value .. "'", 0)
        end
        add_variable(out.vars, name, text)
    elseif kind ~= "table" then
        error("sh.command: a " .. kind .. " names no variable", 0)
    elseif is_command(value) or is_pipeline(value) then
        error("sh.command: a Command is not an argument; use :pipe()", 0)
    elseif active[value] then
        error("sh.command: an argument table contains itself", 0)
    elseif type(rawget(value, "__stdout")) == "string" then
        walk(value, out, active)
    else
        active[value] = true
        collect_table(value, out, active)
        active[value] = nil
    end
end

-- Collect the `n` argument values of `pushenv` in `values`.
local function collect_env(n, values)
    local out = {
        args    = {},
        input   = "",
        sources = {},
        fields  = { __stdout = "", __stderr = "" },
        vars    = {},
    }
    local active = {}
    for i = 1, n do
        collect(values[i], out, active)
    end

    local names = {}
    for name in pairs(out.vars) do
        names[#names + 1] = name
    end
    table.sort(names, byte_less)
    out.env = {}
    for i, name in ipairs(names) do
        out.env[i] = { name = name, value = out.vars[name] }
    end
    out.vars = nil
    return out
end

--- Read the arguments of `pushenv`: the environment variables they name.
--- A string is `"NAME=value"`. A table gives one variable per string key:
--- a string or a number is its value, and `false` removes the variable;
--- its array entries are read as arguments. `nil` and `false` are skipped,
--- and where a variable is named twice the later one counts. A Result is
--- not read for variables: it passes through, as parse() has it.
---@param ... any
---@return table parsed { env, args, input, sources, fields }, where `env`
---                     lists { name, value } in byte order of the names;
---                     `value` is a string, or false to remove the variable
function M.parse_env(...)
    local parsed = guard(collect_env, select("#", ...), { ... })
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
