---@diagnostic disable: undefined-global
--------------------------------------------------------------------------------
-- Tests for libraries and backends that load after sh.install(). install()
-- turns undefined globals into commands, and libraries read optional globals
-- to detect features: luaposix reads `jit` and `bit` on Lua 5.1 and 5.2, and
-- fails when they are command functions. These tests start no process.
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

--------------------------------------------------------------------------------
-- INITIALIZE SH
--------------------------------------------------------------------------------
-- Nothing may load luaposix or luv before install(), or the first test
-- passes whatever install() does.
local sh  = require("sh")
local sys = require("sh.sys")
sh.install()

-- A global that nothing defines: a command outside library loads.
local PROBE = "luash_test_install_probe"

--------------------------------------------------------------------------------
-- RUN TESTS
--------------------------------------------------------------------------------
test("Libraries load after install()", function()
    for _, lib in ipairs({ "posix", "luv" }) do
        local loaded, err = pcall(require, lib)
        local why     = tostring(err):match("^([^\n]-):?\n") or tostring(err)
        local missing = "module '" .. lib .. "' not found"
        local absent  = not loaded and why:find(missing, 1, true) ~= nil
        ok(loaded or absent, lib .. (loaded and " loads" or ": " .. why))
    end
end)

test("A backend loaded after install() sees undefined globals", function()
    local seen = {}
    local function look(step)
        seen[#seen + 1] = step .. "=" .. type(_G[PROBE])
    end
    package.preload["sh.backend.probe"] = function()
        look("load")
        return {
            name      = "probe",
            run       = function() error("probe: run called") end,
            configure = function() look("configure") end,
            available = function()
                look("available")
                return true
            end,
        }
    end
    sh.set_backend("probe")
    local got  = table.concat(seen, " ")
    local want = "load=nil configure=nil available=nil"
    ok(eq(got, want), "nil while it loads, is configured and is asked")
end)

test("Undefined globals are commands outside library loads", function()
    ok(not sys.loading(), "no load in progress")
    ok(type(_G[PROBE]) == "function", "a command after a load")
    local loaded, err = sys.load_pcall(error, "raised in load_pcall", 0)
    ok(not loaded and err == "raised in load_pcall", "load_pcall catches")
    ok(not sys.loading(), "a load that raised has ended")
    ok(type(_G[PROBE]) == "function", "a command after a load that raised")
end)

print(tests_passed .. " passed, " .. tests_failed .. " failed")
if tests_failed > 0 then os.exit(1) end
