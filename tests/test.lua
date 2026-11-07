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

    -- The first file that `template` (a package.path entry) names for each
    -- of `names`, or nil when none exists.
    local function existing(template, names)
        local sep = package.config:sub(1, 1)
        for _, name in ipairs(names) do
            local file = template:gsub("%?", (name:gsub("%.", sep)))
            local f    = io.open(file, "r")
            if f then
                f:close()
                return file
            end
        end
        return nil
    end

    -- Removes every package.path entry that finds `sh` or `sh.command` (in
    -- sh/, at the repository root), so that only standalone/sh.lua can
    -- provide the modules.
    local function drop_sh_sources()
        local kept = {}
        for template in package.path:gmatch("[^;]+") do
            if not existing(template, { "sh", "sh.command" }) then
                kept[#kept + 1] = template
            end
        end
        package.path = table.concat(kept, ";")
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
    if standalone and standalone ~= "" then
        drop_sh_sources()
        prepend_path(pth .. "/../standalone/?.lua")
    else
        prepend_path(pth .. "/../?/init.lua")
    end
    local found = nil
    for template in package.path:gmatch("[^;]+") do
        found = found or existing(template, { "sh" })
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
-- RUN TESTS
--------------------------------------------------------------------------------
test('Check Version', function()
    print(sh.version)
    ok(sh.version == 'Automatic Shell Bindings for Lua / LuaSH 2.0.0')
end)

test('Check command output', function()
    ok(tostring(seq(1, 5)) == '1\n2\n3\n4\n5', 'seq 1 5')
end)

-- Tests that pass input to a command run only on a backend that can.
local no_stdin = "the backend cannot pass input (capabilities().stdin)"

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
    if _VERSION ~= 'Lua 5.1' then
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

print(string.format(
    "%d passed, %d failed, %d skipped",
    tests_passed, tests_failed, tests_skipped
))
-- error() rather than os.exit(1): the interpreter then closes the Lua state,
-- which lets the popen backend remove its private temp directory.
if tests_failed > 0 then error("some tests failed", 0) end
