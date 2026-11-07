---@diagnostic disable: undefined-global, redefined-local
--------------------------------------------------------------------------------
-- Unit tests for sh/command.lua. They start no process: io.popen and
-- os.execute are replaced by functions that record the call and raise.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- INITIALIZE PROJECT PATHS
--------------------------------------------------------------------------------
local function init()
    -- function to prepend `pth` the the package search path, using `pth` as a
    -- key to prevent duplicates

    local function prepend_path(pth)
        ---@diagnostic disable-next-line: undefined-field
        if package.user_modules and (true == package.user_modules[pth]) then
            return
        end
        -- prepend to path
        package.path = pth .. ";" .. package.path
        -- add key to user modules
        if not package.user_modules then package.user_modules = {} end
        package.user_modules[pth] = true
    end

    local pth = debug.getinfo(2).source:match("@?(.*)/")
    -- if this program is called within the current directory then the path
    -- won't contain '/', returning (nil)
    if nil == pth then pth = "." end
    -- remember to remove the traling slash
    prepend_path(pth .. "/?.lua")
    prepend_path(pth .. "/../?.lua")
    prepend_path(pth .. "/../?/init.lua")
    return pth
end

local pth = init()
print("Operating in: " .. pth)

--------------------------------------------------------------------------------
-- INITIALIZE TEST HARNESS
--------------------------------------------------------------------------------
local test = require("gambiarra")

local tests_passed = 0
local tests_failed = 0
require("gambiarra")(function(e, name, msg)
    if e == "pass" then
        print("\27[32m✔\27[0m " .. name .. ": " .. msg)
        tests_passed = tests_passed + 1
    elseif e == "fail" then
        print("\27[31m✘\27[0m " .. name .. ": " .. msg)
        tests_failed = tests_failed + 1
    elseif e == "except" then
        print("\27[31m✘\27[0m " .. name .. ": " .. msg)
        tests_failed = tests_failed + 1
    end
end)

-- Any attempt to start a process is recorded and fails.
local spawned = {}
local function no_process(name)
    return function(...)
        spawned[#spawned + 1] = name
        error("test_command: " .. name .. " called; no process may start")
    end
end
io.popen   = no_process("io.popen")
os.execute = no_process("os.execute")

-- A readable form of a value, for comparisons with eq() whose failure
-- message then shows both sides.
local function show(x)
    if type(x) == "string" then return string.format("%q", x) end
    if type(x) ~= "table" then return tostring(x) end
    local parts = {}
    for i = 1, #x do
        parts[i] = show(x[i])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- The error message of calling f(...), or nil when it did not raise.
local function raises(f, ...)
    local good, err = pcall(f, ...)
    if good then return nil end
    return tostring(err)
end

local function contains(s, part)
    return type(s) == "string" and s:find(part, 1, true) ~= nil
end

-- A fake Result as sh/init.lua makes them; no metatable needed here.
local function result(out, pipeline)
    return {
        __input  = out, __stdout = out, __stderr = "",
        __exitcode = 0, __signal = 0, __pipeline = pipeline,
    }
end

--------------------------------------------------------------------------------
-- LOAD THE MODULE
--------------------------------------------------------------------------------
local globals_before = {}
for k in pairs(_G) do
    globals_before[k] = true
end

local command = require("sh.command")

local new_globals = {}
for k in pairs(_G) do
    if not globals_before[k] then new_globals[#new_globals + 1] = k end
end

local Command  = command.Command
local Pipeline = command.Pipeline
local parse    = command.parse
local quote    = command.quote

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------
test("Module shape", function()
    ok(type(command) == "table", "require returns a table")
    ok(eq(show(new_globals), "{}"), "loading creates no globals")
    local functions = {
        "parse", "quote", "Command", "Pipeline", "set_runner", "render",
        "is_command", "is_pipeline",
    }
    for _, name in ipairs(functions) do
        ok(type(command[name]) == "function", "command." .. name)
    end
end)

test("parse: positional arguments", function()
    local p = parse("a", 1, { "-b", { "c" } })
    ok(eq(show(p.args), show({ "a", "1", "-b", "c" })), "a 1 {-b {c}}")
    ok(eq(p.input, ""), "no input")
    ok(eq(#p.sources, 0), "no sources")
    ok(eq(p.fields.__stdout, ""), "fields.__stdout empty")
    ok(eq(p.fields.__stderr, ""), "fields.__stderr empty")
    ok(p.fields.__exitcode == nil and p.fields.__signal == nil,
        "fields.__exitcode and __signal unset")

    local p = parse("a", nil, false, "b", { false, "c" })
    ok(eq(show(p.args), show({ "a", "b", "c" })), "nil and false skipped")
    ok(eq(show(parse().args), "{}"), "no arguments")
    ok(eq(show(parse(2.5, -1).args), show({ "2.5", "-1" })), "numbers")

    local p = parse({ "-c", "type type", v = true })
    ok(eq(show(p.args), show({ "-c", "type type", "-v" })),
        "array entries before the flags of the same table")
end)

test("parse: invalid positional arguments", function()
    ok(contains(raises(parse, true), "boolean"), "true raises")
    ok(contains(raises(parse, print), "function"), "a function raises")
    ok(raises(parse, Command("ls")) ~= nil, "a Command raises")
    ok(raises(parse, Pipeline(Command("ls"))) ~= nil, "a Pipeline raises")
    local t = { "a" }
    t[2] = t
    ok(contains(raises(parse, t), "contains itself"), "a cyclic table raises")
    local shared = { "x" }
    ok(eq(show(parse(shared, { shared }).args), show({ "x", "x" })),
        "the same table twice is not a cycle")
end)

test("parse: flags", function()
    local p = parse({ format = "%a", v = true, q = false, n = 3, e = "" })
    -- DESIGN.md section 7: sorted keys, one-character keys give -k.
    ok(eq(show(p.args), show({ "-e=", "--format=%a", "-n=3", "-v" })),
        "sorted; q = false absent; e = '' gives -e=")
    ok(eq(show(parse({ empty = "" }).args), show({ "--empty=" })),
        "empty string value of a long key gives --key=")
    ok(eq(show(parse({ l = false }).args), "{}"), "{l = false} emits nothing")

    local p = parse({ zeta = 1, alpha = true, m = "x", beta = true, a = 1 })
    ok(eq(show(p.args),
        show({ "-a=1", "--alpha", "--beta", "-m=x", "--zeta=1" })),
        "flag order is the sorted key order")

    local p = parse({ _private = 1, __other = 2, [2.5] = "x", [true] = 1 })
    ok(eq(show(p.args), "{}"), "_ keys and non-string keys ignored")

    local err = raises(parse, { callback = function() end })
    ok(contains(err, "callback") and contains(err, "function"),
        "a function value raises an error naming the key: " .. tostring(err))
    local err = raises(parse, { opts = {} })
    ok(contains(err, "opts"), "a table value raises an error naming the key")
    ok(contains(raises(parse, { [""] = true }), "empty flag name"),
        "an empty key raises")
end)

test("parse: input, sources and fields", function()
    local p = parse({ __input = "x" }, { __input = "y" })
    ok(eq(p.input, "xy"), "{__input = 'x'}, {__input = 'y'} gives input 'xy'")
    ok(eq(#p.sources, 0), "a plain {__input = s} is no source")

    local pl = Pipeline(Command("seq", 1, 3))
    local r = {
        __stdout = "o", __stderr = "e", __exitcode = 2, __signal = 0,
        __input = "o", __pipeline = pl,
    }
    local p = parse(r)
    ok(eq(p.input, "o"), "Result input")
    ok(#p.sources == 1 and rawequal(p.sources[1], pl), "Result source")
    ok(eq(p.fields.__exitcode, 2), "fields.__exitcode")
    ok(eq(p.fields.__signal, 0), "fields.__signal")
    ok(eq(p.fields.__stdout, "o"), "fields.__stdout")
    ok(eq(p.fields.__stderr, "e"), "fields.__stderr")
    ok(eq(show(p.args), "{}"), "a Result gives no arguments")

    local pl2 = Pipeline(Command("seq", 4, 6))
    local r2  = result("p", pl2)
    r2.__stderr   = "f"
    r2.__exitcode = 5
    local p = parse(r, "-l", { r2 })
    ok(eq(p.input, "op"), "two Results: input in order")
    ok(#p.sources == 2 and rawequal(p.sources[1], pl)
        and rawequal(p.sources[2], pl2), "two Results: sources in order")
    ok(eq(p.fields.__stdout, "op"), "fields.__stdout concatenated")
    ok(eq(p.fields.__stderr, "ef"), "fields.__stderr concatenated")
    ok(eq(p.fields.__exitcode, 5), "fields.__exitcode is the last seen")
    ok(eq(show(p.args), show({ "-l" })), "positional among Results")

    local p = parse(result("z", nil))
    ok(eq(p.input, "z") and #p.sources == 0,
        "a Result without __pipeline adds input, no source")
    local p = parse({ __input = "q", __pipeline = pl })
    ok(eq(#p.sources, 0), "__pipeline without a string __stdout is no source")
    ok(contains(raises(parse, { __input = {} }), "__input"),
        "a table __input raises")
end)

test("quote", function()
    ok(eq(quote("it's"), "'it'\\''s'"), "it's")
    ok(eq(quote("a/b.c_d=e"), "a/b.c_d=e"), "a/b.c_d=e is bare")
    ok(eq(quote("-x:y@z%a+b,c"), "-x:y@z%a+b,c"), "every bare punctuation")
    ok(eq(quote(""), "''"), "empty string")
    ok(eq(quote("a b"), "'a b'"), "space")
    ok(eq(quote("$HOME"), "'$HOME'"), "dollar")
    ok(eq(quote("*"), "'*'"), "glob")
    ok(eq(quote("a;b"), "'a;b'"), "semicolon")
    ok(eq(quote("x\ny"), "'x\ny'"), "newline")
    ok(eq(quote("''"), "''\\'''\\'''"), "two quotes")
    ok(eq(quote(3), "3"), "number")
    ok(raises(quote, {}) ~= nil, "a table raises")
end)

test("Command rendering", function()
    local c = Command("ls", "-l", { color = "auto" }):arg("a b", "")
    ok(eq(tostring(c), "ls -l --color=auto 'a b' ''"), "ls with flag table")

    local c = Command("ls", "-l")
    c:arg("/tmp", "/var")
    c:flag("color", "auto")
    c:flag("a")
    c:flag("l", false)
    ok(eq(tostring(c), "ls -l /tmp /var --color=auto -a"),
        "DESIGN.md 3.4 example")
    ok(eq(command.render(c), tostring(c)), "render(c) is tostring(c)")

    local c = Command("stat", "/bin", { format = "%a %n" })
    ok(eq(tostring(c), "stat /bin '--format=%a %n'"), "stat with format")
    ok(eq(tostring(Command("grep", "it's")), "grep 'it'\\''s'"), "quote")
    ok(eq(tostring(Command("x", { __input = "secret" })), "x"),
        "literal stdin is not rendered")
end)

test("Command validation", function()
    ok(raises(Command) ~= nil, "no name raises")
    ok(raises(Command, "") ~= nil, "empty name raises")
    ok(raises(Command, 5) ~= nil, "number name raises")
    ok(raises(command.render, {}) ~= nil, "render of a plain table raises")
end)

test("Command:flag", function()
    local c = Command("x")
    ok(rawequal(c:flag("l"), c), "flag returns the command")
    ok(eq(show(c:argv()), show({ "x", "-l" })), "flag('l') gives -l")
    local c = Command("x"):flag("color", "auto")
    ok(eq(show(c:argv()), show({ "x", "--color=auto" })), "--color=auto")
    local c = Command("x"):flag("x", false)
    ok(eq(show(c:argv()), show({ "x" })), "flag('x', false) adds nothing")
    local c = Command("x"):flag("n", 3):flag("e", ""):flag("all", true)
    ok(eq(show(c:argv()), show({ "x", "-n=3", "-e=", "--all" })),
        "number, empty string and true values; calls chain")
    local err = raises(Command("x").flag, Command("x"), "bad", {})
    ok(contains(err, "bad"), "an invalid value raises an error naming the key")
    ok(raises(Command("x").flag, Command("x"), 5) ~= nil,
        "a non-string key raises")
end)

test("Command:argv", function()
    local c = Command("ls", "-l", 3)
    local argv = c:argv()
    ok(eq(show(argv), show({ "ls", "-l", "3" })), "argv")
    argv[2] = "changed"
    argv[5] = "added"
    ok(eq(show(c:argv()), show({ "ls", "-l", "3" })), "argv is a new table")
    ok(not rawequal(c:argv(), c:argv()), "each call gives a new table")
end)

test("Command:input", function()
    local c = Command("cat")
    ok(rawequal(c:input("data"), c), "input returns the command")
    ok(eq(c.stdin, "data"), "string input")

    local pl = Pipeline(Command("seq", 1, 3))
    local r  = result("1\n2\n3\n", pl)
    c:input(r)
    ok(eq(c.stdin, "1\n2\n3\n"), "Result input")
    ok(#c.sources == 1 and rawequal(c.sources[1], pl),
        "Result recorded as the source")
    ok(eq(tostring(c), "seq 1 3 | cat"), "a Result's pipeline renders")

    c:input("other")
    ok(eq(c.stdin, "other") and #c.sources == 0, "input replaces input")
    c:input({ __input = "lit" })
    ok(eq(c.stdin, "lit") and #c.sources == 0, "{__input = s} input")
    c:input(nil)
    ok(eq(c.stdin, "") and #c.sources == 0, "nil clears the input")

    local c = Command("wc", r, "-l")
    ok(eq(c.stdin, "1\n2\n3\n"), "a Result argument gives stdin")
    ok(#c.sources == 1 and rawequal(c.sources[1], pl),
        "a Result argument gives a source")
    c:arg({ __input = "more" })
    ok(eq(c.stdin, "1\n2\n3\nmore"), "arg() appends input")

    ok(raises(c.input, c, true) ~= nil, "a boolean raises")
    ok(raises(c.input, c, {}) ~= nil, "a table without __input raises")
    ok(raises(c.input, c, Command("x")) ~= nil, "a Command raises")
end)

test("Pipeline", function()
    local p = Command("seq", 1, 10):pipe(Command("wc", "-l"))
    ok(command.is_pipeline(p), "Command:pipe gives a Pipeline")
    ok(eq(tostring(p), "seq 1 10 | wc -l"), "seq 1 10 | wc -l")
    ok(eq(command.render(p), "seq 1 10 | wc -l"), "render(p)")

    local a, b, c = Command("ls", "-l"), Command("grep", "foo"), Command("wc")
    local p3 = Pipeline(a, b):pipe(c)
    ok(eq(#p3:commands(), 3), "Pipeline(a, b):pipe(c) has three stages")
    ok(eq(tostring(p3), "ls -l | grep foo | wc"), "three stages render")

    local p2   = Pipeline(a, b)
    local list = p2:commands()
    list[3] = c
    table.remove(list, 1)
    ok(eq(#p2:commands(), 2), "modifying commands() leaves the Pipeline")
    ok(rawequal(p2:commands()[1], a) and rawequal(p2:commands()[2], b),
        "commands() holds the stages in order")
    ok(rawequal(p2:pipe(c), p2), "Pipeline:pipe returns the pipeline")
    ok(eq(#p2:commands(), 3), "Pipeline:pipe appends")

    local joined = Pipeline(Pipeline(a, b), c)
    ok(eq(tostring(joined), "ls -l | grep foo | wc"), "a Pipeline splices in")
    local twice = Pipeline(a, b)
    twice:pipe(twice)
    ok(eq(#twice:commands(), 4), "a Pipeline piped into itself doubles")
    ok(eq(tostring(Pipeline()), ""), "an empty Pipeline renders as ''")

    ok(raises(Pipeline, a, "wc") ~= nil, "a string stage raises")
    ok(raises(Pipeline, a, nil, b) ~= nil, "a nil stage raises")
    ok(raises(a.pipe, a, {}) ~= nil, "Command:pipe of a table raises")
end)

test("Pipeline rendering of sources", function()
    local r1 = result("1\n", Pipeline(Command("seq", 1, 10)))
    local r2 = result("2\n", Pipeline(Command("seq", 20, 25)))

    local wc = Command("wc", r1, r2, "-l")
    ok(eq(tostring(wc), "{ seq 1 10; seq 20 25; } | wc -l"),
        "a Command with two sources renders a group")
    ok(eq(tostring(Pipeline(wc)), "{ seq 1 10; seq 20 25; } | wc -l"),
        "a stage with two sources renders a group")
    ok(eq(tostring(Pipeline(wc, Command("cat"))),
        "{ seq 1 10; seq 20 25; } | wc -l | cat"), "group, then a stage")

    local one = Command("wc", r1, "-l")
    ok(eq(tostring(one), "seq 1 10 | wc -l"), "one source")
    -- How sh/init.lua extends the pipeline of a single source: the
    -- Command's own source is the stage before it and is not repeated.
    ok(eq(tostring(Pipeline(r1.__pipeline, one)), "seq 1 10 | wc -l"),
        "the sources of a later stage are not rendered")

    local r3 = result("3\n", Pipeline(wc))
    ok(eq(tostring(Command("sort", r3, r1)),
        "{ { seq 1 10; seq 20 25; } | wc -l; seq 1 10; } | sort"),
        "groups nest")

    local lit = Command("wc", r1, { __input = "x" })
    ok(eq(tostring(lit), "seq 1 10 | wc"), "literal input beside a Result")

    -- A Command fed by a Pipeline it belongs to renders once, not forever.
    local sed = Command("sed", "s/a/b/")
    sed:input(result("b", Pipeline(sed)))
    ok(eq(tostring(sed), "sed s/a/b/ | sed s/a/b/"), "a cycle terminates")
end)

test("__bor", function()
    local ca, cb = Command("a"), Command("b")
    local bor = getmetatable(ca).__bor
    ok(type(bor) == "function", "Command metatable has __bor")
    ok(getmetatable(Pipeline(ca)).__bor == bor, "Pipeline metatable has __bor")
    local p = bor(ca, cb)
    ok(command.is_pipeline(p) and eq(tostring(p), "a | b"),
        "__bor(a, b) builds the Pipeline a | b")
    local p2 = bor(p, Command("c"))
    ok(eq(tostring(p2), "a | b | c") and eq(#p:commands(), 2),
        "__bor of a Pipeline builds a new one and leaves the operand")
    ok(eq(tostring(bor(ca, p)), "a | a | b"), "__bor(Command, Pipeline)")
    ok(raises(bor, ca, 5) ~= nil, "__bor with a number raises")

    -- Lua 5.3 and newer call __bor. Lua 5.1 and 5.2 reject the | operator
    -- when compiling. A LuaJIT may compile it (the Homebrew LuaJIT 2.1
    -- parses bitwise operators) and then raise "attempt to perform
    -- arithmetic" for tables, because it never calls __bor.
    local interpreter = (rawget(_G, "jit") and jit.version) or _VERSION
    local expected    = rawget(_G, "jit") == nil
        and _VERSION ~= "Lua 5.1" and _VERSION ~= "Lua 5.2"
    _G.luash_test_a = ca
    _G.luash_test_b = cb
    local source = "return luash_test_a | luash_test_b"
    local chunk, err = (loadstring or load)(source)
    local good, p = false, nil
    if chunk then good, p = pcall(chunk) end
    _G.luash_test_a = nil
    _G.luash_test_b = nil
    if expected then
        ok(chunk ~= nil, "the | operator compiles on " .. interpreter)
        ok(good and command.is_pipeline(p) and eq(tostring(p), "a | b"),
            "luash_test_a | luash_test_b renders as a | b")
    elseif not chunk then
        ok(true, "note: " .. interpreter .. " has no | operator ("
            .. tostring(err) .. ")")
    elseif not good then
        ok(true, "note: " .. interpreter .. " compiles | but does not call "
            .. "__bor (" .. tostring(p) .. ")")
    else
        ok(command.is_pipeline(p) and eq(tostring(p), "a | b"),
            "note: " .. interpreter .. " calls __bor; a | b renders")
    end
end)

test("__name and recognition", function()
    local c = Command("ls")
    local p = Pipeline(c)
    ok(eq(getmetatable(c).__name, "sh.Command"), "Command __name")
    ok(eq(getmetatable(p).__name, "sh.Pipeline"), "Pipeline __name")
    ok(command.is_command(c) and not command.is_command(p), "is_command")
    ok(command.is_pipeline(p) and not command.is_pipeline(c), "is_pipeline")
    ok(not command.is_command("ls") and not command.is_command({})
        and not command.is_command(nil), "non-Commands")
    ok(not command.is_pipeline(42) and not command.is_pipeline({}),
        "non-Pipelines")
    local foreign = setmetatable({}, { __name = "sh.Command" })
    ok(command.is_command(foreign), "recognised by __name alone")
    local locked = setmetatable({}, { __metatable = "locked" })
    ok(not command.is_command(locked), "a protected metatable is no Command")
end)

test("run", function()
    local c = Command("x")
    ok(contains(raises(c.run, c), "no runner"),
        "Command:run() before set_runner raises 'no runner'")
    local p = Pipeline(Command("a"), Command("b"))
    ok(contains(raises(p.run, p), "no runner"),
        "Pipeline:run() before set_runner raises 'no runner'")

    local calls = {}
    local function stub(cmd, input)
        local r = { __stdout = cmd.name, __input = cmd.name, n = #calls + 1 }
        calls[#calls + 1] = { cmd = cmd, input = input, result = r }
        return r
    end
    ok(command.set_runner(stub) == nil, "set_runner returns no previous")

    local r = c:run()
    ok(eq(#calls, 1), "Command:run() called the runner once")
    ok(rawequal(r, calls[1].result), "run() returns what the runner returns")
    ok(rawequal(calls[1].cmd, c), "the runner received the Command")
    ok(calls[1].input == nil, "Command:run() passes no input")

    calls = {}
    local a, b, d = Command("a"), Command("b"), Command("d")
    local r = Pipeline(a, b, d):run()
    ok(eq(#calls, 3), "Pipeline:run() called the runner once per stage")
    ok(rawequal(calls[1].cmd, a) and rawequal(calls[2].cmd, b)
        and rawequal(calls[3].cmd, d), "stages ran left to right")
    ok(calls[1].input == nil, "the first stage gets no input")
    ok(rawequal(calls[2].input, calls[1].result)
        and rawequal(calls[3].input, calls[2].result),
        "each later stage gets the Result before it as input")
    ok(rawequal(r, calls[3].result), "Pipeline:run() returns the last Result")

    ok(contains(raises(Pipeline().run, Pipeline()), "empty"),
        "running an empty Pipeline raises")
    ok(raises(command.set_runner, 5) ~= nil, "set_runner(5) raises")
    ok(rawequal(command.set_runner(nil), stub), "set_runner returns previous")
    ok(contains(raises(c.run, c), "no runner"), "set_runner(nil) uninstalls")
end)

test("No process started", function()
    ok(eq(show(spawned), "{}"), "io.popen and os.execute were never called")
end)

print(tests_passed .. " passed, " .. tests_failed .. " failed")
if tests_failed > 0 then os.exit(1) end
