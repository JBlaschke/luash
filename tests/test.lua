---@diagnostic disable: undefined-global, redefined-local
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

    -- The file that `template` (a package.path entry) names for module
    -- `name`, or nil when it does not exist.
    local function existing(template, name)
        local sep  = package.config:sub(1, 1)
        local file = template:gsub("%?", (name:gsub("%.", sep)))
        local f    = io.open(file, "r")
        if f then
            f:close()
            return file
        end
        return nil
    end

    -- Makes require() of a module sh.* that standalone/sh.lua does not
    -- preload fail, instead of loading it from sh/ or from a copy that
    -- luarocks installed: every searcher after package.preload refuses
    -- the name. package.path stays as it is, so that the libraries of the
    -- backends, such as luaposix, are found where they are installed.
    local function refuse_sh_sources()
        local searchers = package.searchers or package.loaders
        for i = 2, #searchers do
            local search = searchers[i]
            searchers[i] = function(name, ...)
                if type(name) == "string" and name:find("^sh%.") then
                    error(
                        "module '" .. name .. "' is not in standalone/sh.lua"
                        .. "; run make standalone", 0
                    )
                end
                return search(name, ...)
            end
        end
    end

    local pth = debug.getinfo(2).source:match("@?(.*)/")
    -- if this program is called within the current directory then the path
    -- won't contain '/', returning (nil)
    if nil == pth then pth = "." end
    -- remember to remove the traling slash
    prepend_path(pth .. "/?.lua")
    prepend_path(pth .. "/../?.lua")
    -- LUASH_STANDALONE tests the single-file build instead of sh/ (make
    -- standalone builds it). Its modules are preloaded by standalone/sh.lua,
    -- and none may come from sh/ instead.
    local standalone = os.getenv("LUASH_STANDALONE")
    standalone = standalone ~= nil and standalone ~= ""
    if standalone then
        refuse_sh_sources()
        prepend_path(pth .. "/../standalone/?.lua")
    else
        prepend_path(pth .. "/../?/init.lua")
    end
    -- The file that require("sh") loads: the first package.path entry that
    -- names an existing one.
    local found = nil
    for template in package.path:gmatch("[^;]+") do
        found = found or existing(template, "sh")
    end
    -- Without standalone/sh.lua, require("sh") would get sh/ or an
    -- installed copy, and the run would test the wrong library.
    local standalone_file = pth .. "/../standalone/sh.lua"
    if standalone and found ~= standalone_file then
        local would = found and ("load " .. found) or "find nothing"
        error(
            "LUASH_STANDALONE is set, but require('sh') would " .. would
            .. "; run make standalone", 0
        )
    end
    return pth, found
end

local pth, sh_file = init()
print("Operating in: " .. pth)
print("Library: " .. tostring(sh_file))

--------------------------------------------------------------------------------
-- INITIALIZE TEST HARNESS
--------------------------------------------------------------------------------
local test = require('gambiarra')

local tests_passed  = 0
local tests_failed  = 0
local tests_skipped = 0
---@diagnostic disable-next-line: redefined-local
require('gambiarra')(function(e, test, msg)
    if e == 'pass' then
        print("[32m✔[0m "..test..': '..msg)
        tests_passed = tests_passed + 1
    elseif e == 'fail' then
        print("[31m✘[0m "..test..': '..msg)
        tests_failed = tests_failed + 1
    elseif e == 'except' then
        print("[31m✘[0m "..test..': '..msg)
        tests_failed = tests_failed + 1
    end
end)

-- Records that test `name` did not run. The line must not start with
-- "SKIP:": tests/run_all.sh reports a file with such a line as skipped.
local function skip(name, why)
    print("- " .. name .. ": skipped, " .. why)
    tests_skipped = tests_skipped + 1
end

--------------------------------------------------------------------------------
-- INITIALIZE SH
--------------------------------------------------------------------------------
local sh = require('sh')

-- LUASH_BACKEND names the backend to test (tests/run_all.sh sets it). A
-- backend this interpreter cannot use, such as posix without luaposix,
-- skips the whole file.
local wanted = os.getenv("LUASH_BACKEND")
if wanted and wanted ~= "" and wanted ~= "auto" then
    local found = false
    for _, name in ipairs(sh.available_backends()) do
        if name == wanted then found = true end
    end
    if not found then
        print("SKIP: backend " .. wanted .. " unavailable")
        local _, why = pcall(sh.backend_name)
        print("Reason: " .. tostring(why))
        os.exit(0)
    end
end

local caps = sh.capabilities()
local caps_text = {}
for key, value in pairs(caps) do
    caps_text[#caps_text + 1] = key .. " = " .. tostring(value)
end
table.sort(caps_text)
print("Backend: " .. sh.backend_name())
print("Capabilities: " .. table.concat(caps_text, ", "))

sh.install()
sh.__raise_errors = false

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Runs `f` with the sh.config fields in `settings` set, then restores them,
-- also when `f` raises. Returns the first value `f` returns.
local function with_config(settings, f)
    local saved = {}
    for key, value in pairs(settings) do
        saved[key]     = sh.config[key]
        sh.config[key] = value
    end
    local done, value = pcall(f)
    for key in pairs(settings) do
        sh.config[key] = saved[key]
    end
    if not done then error(value, 0) end
    return value
end

-- A table of chunk lists by stream, and a sh.config.sink that fills it.
local function collector()
    local got = { stdout = {}, stderr = {}, trace = {} }
    local function sink(stream, chunk)
        got[stream] = got[stream] or {}
        table.insert(got[stream], chunk)
    end
    return got, sink
end

-- The error message of f(...), or nil when it does not raise.
local function raised(f, ...)
    local done, err = pcall(f, ...)
    if done then return nil end
    return err
end

-- The output of `seq 1 n`.
local function seq_text(n)
    local lines = {}
    for i = 1, n do
        lines[i] = tostring(i)
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Input of about `size` bytes for the large-input tests. Strategy basic
-- puts the input on the command line, which Linux limits to 128 KiB per
-- argument, so it gets 96 KB.
local function big_input(name, unit, size)
    if caps.strategy == 'basic' and size > 96000 then
        print("- " .. name .. ": 96 KB instead, popen/basic passes input"
            .. " on the command line")
        size = 96000
    end
    return string.rep(unit, math.floor(size / #unit))
end

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------
test('Check Version', function()
    print(sh.version)
    ok(sh.version == 'Automatic Shell Bindings for Lua / LuaSH 2.0.0')
end)

test('Check command output', function()
    ok(tostring(seq(1, 5)) == '1\n2\n3\n4\n5', 'seq 1 5')
end)

-- A strict _G, as safer.lua or strict.lua give a program, raises on an
-- assignment to a new global. Running a command must write none: the
-- posix backend once assigned `_` while waiting for the child. The hook
-- records each write with its location and drops it.
test('Check no global is written while a command runs', function()
    local gmt     = getmetatable(_G)
    local seen    = {}
    local written = {}
    setmetatable(_G, {
        __index    = gmt and gmt.__index,
        __newindex = function(_, name)
            local info  = debug.getinfo(2, 'Sl')
            local entry = tostring(name) .. ' at ' .. info.short_src .. ':'
                .. info.currentline
            if not seen[entry] then
                seen[entry] = true
                written[#written + 1] = entry
            end
        end,
    })
    local done, err = pcall(function()
        ok(tostring(sh.echo('hello')) == 'hello', 'echo under a strict _G')
        if caps.stdin then
            local r = sh.cat(sh.echo('piped'))
            ok(tostring(r) == 'piped', 'a pipeline under a strict _G')
        end
    end)
    setmetatable(_G, gmt)
    if not done then error(err, 0) end
    ok(
        #written == 0,
        #written == 0 and 'no global written'
            or 'globals written: ' .. table.concat(written, ', ')
    )
end)

-- Tests that pass input to a command, or check an exit status, run only on
-- a backend that can.
local no_stdin    = "the backend cannot pass input (capabilities().stdin)"
local no_exitcode = "the backend cannot report exit codes"
    .. " (capabilities().exitcode)"

if caps.stdin then
    test('Check command input', function()
        local r = grep('a.*b', {
            __input = 'arc\narabic\nabbey\n'
        })
        ok(tostring(r) == 'arabic\nabbey', 'grep a.*b')
    end)

    test('Check command pipeline', function()
        local r = wc(seq(1, 10), '-l')
        ok(tonumber(tostring(r)) == 10, 'seq 1 10 | wc -l')

        local r = seq(1, 10) : wc('-l')
        ok(tonumber(tostring(r)) == 10, 'seq 1 10 | wc -l')

        local r = wc(seq(1, 10), seq(20, 25), '-l')
        ok(tonumber(tostring(r)) == 16, '(seq 1 10 ; seq 20 25) | wc -l')
    end)
else
    skip('Check command input', no_stdin)
    skip('Check command pipeline', no_stdin)
end

test('Check command structure', function()
    local r = seq(1, 3)
    ok(r.__input == '1\n2\n3\n', 'seq 1 3: output')
    -- popen basic and minimal cannot report the exit status on Lua 5.1 and
    -- LuaJIT (DESIGN.md section 6.3).
    if not caps.exitcode then
        skip('Check command structure: exit codes', no_exitcode)
    else
        ok(r.__signal == 0, 'seq 1 3: signal')
        ok(r.__exitcode == 0, 'seq 1 3: exit code')
        local r = sh.command('false')()
        ok(r.__exitcode ~= 0, 'false: exit code')
        local r = sh.command('true')()
        ok(r.__exitcode == 0, 'true: exit code')
        local r = ls('/missing')
        ok(r.__exitcode ~= 0, 'ls /missing: exit code')
    end
end)

test('Check command with predefined args', function()
    local seq10 = sh.command('seq', 10)
    ok(tostring(seq10(12)) == '10\n11\n12', 'seq 10 12')
    ok(tostring(seq10(15)) == '10\n11\n12\n13\n14\n15', 'seq 10 15')
    ok(tostring(seq10('-1', 8)) == '10\n9\n8', 'seq 10 9 8')
end)

test('Check sh called as function', function()
    local seq10 = sh('seq', 10)
    ok(type(seq10) == 'function', 'sh() returns a command function')
    ok(tostring(seq10(12)) == '10\n11\n12', 'seq 10 12')
end)

if tostring(uname()) == "Linux" then
    test('Check command with table args (Linux only ATM)', function()
        local r    = stat('/bin', {format='%a %n'})
        local rstr = tostring(r)
        ok(
            rstr == "777 /bin" or rstr == "755 /bin",
            'stat --format "%a %n" /bin'
        )
    end)
end

test('Check concatenation', function()
    ok(echo("te ").."st" == "test" and "te"..echo(" st") == "test")
end)

test('Check listing directory', function()
    local files = tostring(ls(pth))
    local matches = {}
    matches["gambiarra.lua"] = false
    matches["test.lua"]      = false
    for f in string.gmatch(files, "[^\n]+") do
        matches[f] = true
    end
    CHECK = function ()
        for _, v in pairs(matches) do if false == v then return false end end
        return true
    end
    ok(CHECK())
end)

--------------------------------------------------------------------------------
-- 2.0 TESTS
--------------------------------------------------------------------------------
test('Check sh.Command and sh.Pipeline rendering', function()
    local c = sh.Command('ls', '-l', {color = 'auto'}):arg('a b', '')
    ok(eq(tostring(c), "ls -l --color=auto 'a b' ''"), 'Command with a table')
    ok(eq(getmetatable(c).__name, 'sh.Command'), 'Command __name')

    c = sh.Command('ls'):flag('a'):flag('color', 'auto'):flag('l', false)
    ok(eq(tostring(c), 'ls -a --color=auto'), 'Command:flag')
    ok(eq(c:argv(), {'ls', '-a', '--color=auto'}), 'Command:argv')
    ok(eq(tostring(sh.Command('echo', "it's")), "echo 'it'\\''s'"), 'quote')

    local p = sh.Command('seq', 1, 10):pipe(sh.Command('wc', '-l'))
    ok(eq(tostring(p), 'seq 1 10 | wc -l'), 'Command:pipe')
    ok(eq(getmetatable(p).__name, 'sh.Pipeline'), 'Pipeline __name')

    p = sh.Pipeline(sh.Command('ls'), sh.Command('sort'))
    p:pipe(sh.Command('head', '-n', 1))
    ok(eq(tostring(p), 'ls | sort | head -n 1'), 'sh.Pipeline')
    ok(eq(#p:commands(), 3), 'Pipeline:commands')
end)

test('Check sh.Command and sh.Pipeline runs', function()
    local r = sh.Command('seq', 1, 3):run()
    ok(eq(r.__stdout, '1\n2\n3\n'), 'Command:run')
    ok(eq(tostring(r.__pipeline), 'seq 1 3'), 'Command:run __pipeline')
    if not caps.stdin then
        skip('Check sh.Command and sh.Pipeline runs: input', no_stdin)
        return
    end
    r = sh.Command('seq', 1, 10):pipe(sh.Command('wc', '-l')):run()
    ok(eq(tonumber(tostring(r)), 10), 'Pipeline:run')
    ok(eq(tostring(r.__pipeline), 'seq 1 10 | wc -l'), 'Pipeline:run, provenance')
    r = sh.Command('grep', 'b'):input('a\nb\nc\n'):run()
    ok(eq(r.__stdout, 'b\n'), 'Command:input')
end)

test('Check __pipeline of results', function()
    local r = sh.seq(1, 3)
    ok(eq(tostring(r.__pipeline), 'seq 1 3'), 'seq 1 3')
    ok(rawequal(r:cd('.').__pipeline, r.__pipeline), 'a builtin passes it')
    if not caps.stdin then
        skip('Check __pipeline of results: chains', no_stdin)
        return
    end
    r = sh.seq(1, 10):wc('-l')
    ok(eq(tostring(r.__pipeline), 'seq 1 10 | wc -l'), 'chained')
    r = sh.seq(1, 3):cd('.'):wc('-l')
    ok(eq(tostring(r.__pipeline), 'seq 1 3 | wc -l'), 'builtin in a chain')
    r = sh.wc(sh.seq(1, 10), sh.seq(20, 25), '-l')
    ok(eq(
        tostring(r.__pipeline), '{ seq 1 10; seq 20 25; } | wc -l'
    ), 'grouped')
end)

test('Check table flags', function()
    local r = sh.printf('%s\n', {b = false, a = true})
    ok(eq(r.__stdout, '-a\n'), 'false is omitted')
    r = sh.printf('%s\n', {z = 0, beta = true, e = '', alpha = 'x'})
    ok(eq(r.__stdout, '--alpha=x\n--beta\n-e=\n-z=0\n'), 'sorted by key')
end)

test('Check verbose output through sh.config.sink', function()
    local got, sink = collector()
    local r = with_config({verbose = true, sink = sink}, function()
        return sh.seq(1, 1500)
    end)
    ok(r.__stdout == seq_text(1500), 'seq 1 1500: output')
    ok(table.concat(got.stdout) == r.__stdout, 'seq 1 1500: sink stdout')
    ok(eq(table.concat(got.stderr), ''), 'seq 1 1500: sink stderr')

    got, sink = collector()
    r = with_config({verbose = true, sink = sink}, function()
        return sh.sh('-c', "printf 'a\\rb\\r'; printf 'x\\n' >&2")
    end)
    ok(eq(table.concat(got.stdout), r.__stdout), 'printf: sink stdout')
    ok(eq(table.concat(got.stderr), r.__stderr), 'printf: sink stderr')
    if caps.separate_stderr then
        ok(eq(r.__stdout, 'a\rb\r'), 'printf: stdout bytes')
        ok(eq(r.__stderr, 'x\n'), 'printf: stderr bytes')
    else
        ok(eq(r.__stdout, 'a\rb\rx\n'), 'printf: merged bytes')
        ok(eq(r.__stderr, ''), 'printf: stderr empty')
    end
end)

test('Check trace lines', function()
    local got, sink = collector()
    with_config({trace = true, sink = sink}, function()
        sh.seq(1, 3)
        sh.echo('a b', "it's")
    end)
    ok(eq(
        table.concat(got.trace), "+ seq 1 3\n+ echo 'a b' 'it'\\''s'\n"
    ), 'one line per run')
    ok(eq(#got.stdout + #got.stderr, 0), 'no output without verbose')
    if not caps.stdin then
        skip('Check trace lines: chains', no_stdin)
        return
    end
    got, sink = collector()
    with_config({trace = true, sink = sink}, function()
        sh.seq(1, 3):wc('-l')
        sh.wc(sh.seq(1, 2), sh.seq(3, 4), '-l')
    end)
    ok(eq(table.concat(got.trace), table.concat({
        "+ seq 1 3\n", "+ seq 1 3 | wc -l\n",
        "+ seq 1 2\n", "+ seq 3 4\n", "+ { seq 1 2; seq 3 4; } | wc -l\n",
    })), 'every stage up to this one')
end)

test('Check missing program', function()
    local name = 'luash-no-such-program-xyz'
    local r    = sh.command(name)()
    if caps.exitcode then ok(eq(r.__exitcode, 127), 'exit code 127') end
    if caps.separate_stderr then
        ok(r.__stderr:find(name, 1, true) ~= nil, 'stderr names it')
        ok(eq(r.__stdout, ''), 'stdout empty')
    else
        ok(r.__stdout:find(name, 1, true) ~= nil, 'merged output names it')
    end
    if not caps.exitcode then
        skip('Check missing program: raise_errors', no_exitcode)
        return
    end
    local err = with_config({raise_errors = true}, function()
        return raised(sh.command(name))
    end)
    ok(err ~= nil and err:find(name, 1, true) ~= nil, 'raises, naming it')
end)

test('Check error messages', function()
    local r = sh.sh('-c', 'exit 3')
    ok(eq(r.__exitcode, caps.exitcode and 3 or 0), 'raise_errors off')
    if not caps.exitcode then
        skip('Check error messages', no_exitcode)
        return
    end
    with_config({raise_errors = true}, function()
        ok(eq(raised(sh.seq, 1, 2), nil), 'no error on success')
        ok(eq(
            raised(sh.sh, '-c', 'exit 3'), "sh -c 'exit 3': exit status 3"
        ), 'exit status')

        local err = raised(function() sh.sh('-c', 'exit 3') end)
        ok(tostring(err):match(
            "test%.lua:%d+: sh %-c 'exit 3': exit status 3$"
        ) ~= nil, 'raised at the caller: ' .. tostring(err))

        err = raised(sh.sh, '-c', 'echo oops >&2; exit 2')
        if caps.separate_stderr then
            ok(eq(err, 'oops'), 'the trimmed stderr')
        else
            local msg = "sh -c 'echo oops >&2; exit 2': exit status 2"
            ok(eq(err, msg), 'exit status, stderr merged')
        end

        err = raised(sh.sh, '-c', 'kill -9 $$')
        if caps.signals then
            ok(eq(err, "sh -c 'kill -9 $$': killed by signal 9"), 'signal')
        else
            ok(eq(err, "sh -c 'kill -9 $$': exit status 137"), '128 + 9')
        end

        if caps.stdin then
            err = raised(function()
                local _ = sh.seq(1, 3):sh('-c', 'cat > /dev/null; exit 4')
            end)
            ok(tostring(err):match(
                "seq 1 3 | sh %-c 'cat > /dev/null; exit 4': exit status 4$"
            ) ~= nil, 'the whole pipeline: ' .. tostring(err))
        end
    end)
end)

test('Check large input through cat', function()
    if not caps.stdin then
        skip('Check large input through cat', no_stdin)
        return
    end
    local name = 'Check large input through cat'
    local big  = big_input(name, '0123456789abcdef\n', 340000)
    local r    = sh.cat({__input = big})
    ok(eq(#r.__stdout, #big), 'length')
    ok(r.__stdout == big, 'content')
end)

test('Check head -c 1 on 1 MB of input', function()
    if not caps.stdin then
        skip('Check head -c 1 on 1 MB of input', no_stdin)
        return
    end
    local name  = 'Check head -c 1 on 1 MB of input'
    local input = big_input(name, 'x', 1000000)
    local r     = sh.head('-c', 1, {__input = input})
    ok(eq(r.__stdout, 'x'), 'first byte, and the host survives SIGPIPE')
    if caps.exitcode then ok(eq(r.__exitcode, 0), 'exit code 0') end
end)

test('Check sh.__verbose and sh.__raise_errors aliases', function()
    with_config({verbose = false, raise_errors = false}, function()
        sh.__verbose = true
        ok(eq(sh.config.verbose, true), 'sh.__verbose writes the config')
        sh.config.verbose = false
        ok(eq(sh.__verbose, false), 'sh.__verbose reads the config')
        sh.__raise_errors = true
        ok(eq(sh.config.raise_errors, true), 'sh.__raise_errors writes')
        sh.config.raise_errors = false
        ok(eq(sh.__raise_errors, false), 'sh.__raise_errors reads')
        ok(rawget(sh, '__verbose') == nil, 'no raw sh.__verbose')
        ok(rawget(sh, '__raise_errors') == nil, 'no raw sh.__raise_errors')
    end)
end)

-- Last: it changes the working directory, and restores it.
test('Check cd, pushd and popd', function()
    -- pwd -P: a cd emulated on the popen backend resolves symbolic links.
    local function here() return tostring(sh.pwd('-P')) end
    local start = here()
    local done, err = pcall(function()
        ok(eq(sh.cd('/').__exitcode, 0), 'cd /')
        ok(eq(here(), '/'), 'pwd after cd /')
        sh.cd(start)
        ok(eq(here(), start), 'pwd after cd back')

        ok(eq(sh.pushd('/').__exitcode, 0), 'pushd /')
        ok(eq(here(), '/'), 'pwd after pushd /')
        ok(eq(sh.popd().__exitcode, 0), 'popd')
        ok(eq(here(), start), 'pwd after popd')

        local r = sh.popd()
        ok(r.__exitcode ~= 0 and r.__stderr ~= '', 'popd on an empty stack')
        r = sh.cd('/luash-no-such-directory')
        ok(r.__exitcode ~= 0 and r.__stderr ~= '', 'cd to a missing directory')
        ok(eq(here(), start), 'pwd after a failed cd')
    end)
    sh.cd(start)
    if not done then error(err, 0) end
end)

print(string.format(
    "%d passed, %d failed, %d skipped",
    tests_passed, tests_failed, tests_skipped
))
-- error() rather than os.exit(1): the interpreter then closes the Lua state,
-- which lets the popen backend remove its private temp directory.
if tests_failed > 0 then error("some tests failed", 0) end
