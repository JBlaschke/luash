---@diagnostic disable: undefined-global, redefined-local
-- Backend contract test (handoff/DESIGN.md sections 4 and 5).
--
--     lua tests/test_backend.lua <posix|luv|popen|fake> [strategy]
--
-- Prints "SKIP: <reason>" and exits 0 when the backend cannot run on this
-- interpreter. Exits 1 when a check fails or the module does not load;
-- under popen's basic strategy, the 340 KB stdin check may fail where the
-- system refuses a command line that long (see main). Required from
-- another test file (`require("test_backend")`) it starts nothing and
-- returns run_contract(B, name, strategy), which runs the checks with the
-- caller's gambiarra reporter.

--------------------------------------------------------------------------------
-- INITIALIZE PROJECT PATHS
--------------------------------------------------------------------------------
local function init()
    -- prepend `pth` to the package search path, using `pth` as a key to
    -- prevent duplicates
    local function prepend_path(pth)
        ---@diagnostic disable-next-line: undefined-field
        if package.user_modules and (true == package.user_modules[pth]) then
            return
        end
        package.path = pth .. ";" .. package.path
        if not package.user_modules then package.user_modules = {} end
        package.user_modules[pth] = true
    end

    local pth = debug.getinfo(2).source:match("@?(.*)/")
    -- called from its own directory, the path has no '/' (nil)
    if nil == pth then pth = "." end
    prepend_path(pth .. "/?.lua")
    prepend_path(pth .. "/../?.lua")
    prepend_path(pth .. "/../?/init.lua")
    return pth
end

init()

local test = require("gambiarra")

--------------------------------------------------------------------------------
-- CONTRACT CHECKS
--------------------------------------------------------------------------------
local BIG = string.rep("0123456789abcdef\n", 20000)   -- 340 KB
local CAPABILITY_KEYS = {
    "stdin", "separate_stderr", "streaming", "exitcode", "signals",
}
local CONTRACT = {
    "available", "capabilities", "configure", "run", "chdir", "getcwd",
}

local function describe(caps)
    local parts = {}
    for _, k in ipairs(CAPABILITY_KEYS) do
        parts[#parts + 1] = k .. "=" .. tostring(caps[k])
    end
    return table.concat(parts, " ")
end

local function run_collecting(B, argv)
    local outs, errs = {}, {}
    local r = B.run(argv, "", {
        on_stdout = function(chunk) outs[#outs + 1] = chunk end,
        on_stderr = function(chunk) errs[#errs + 1] = chunk end,
    })
    return r, table.concat(outs), table.concat(errs), #outs
end

local function run_contract(B, name, strategy)
    local caps = B.capabilities()
    print("backend " .. name .. ": " .. describe(caps))

    test("name and capabilities", function()
        ok(B.name == name, "B.name is " .. name)
        for _, k in ipairs(CONTRACT) do
            ok(type(B[k]) == "function", "B." .. k .. " is a function")
        end
        ok(caps.name == name, "capabilities().name is " .. name)
        for _, k in ipairs(CAPABILITY_KEYS) do
            ok(
                type(caps[k]) == "boolean",
                "capabilities()." .. k .. " is boolean"
            )
        end
        if strategy then
            ok(
                caps.strategy == strategy,
                "capabilities().strategy is " .. strategy
            )
        end
    end)

    test("echo", function()
        local r = B.run({"echo", "hello"}, "", {})
        ok(r.stdout == "hello\n", "stdout is hello")
        ok(r.stderr == "", "stderr is empty")
        ok(r.cause == "exited", "cause is exited")
        ok(r.signal == 0, "signal is 0")
        if caps.exitcode then ok(r.exitcode == 0, "exitcode is 0") end
    end)

    if caps.stdin then
        test("stdin", function()
            local r = B.run({"cat"}, "abc\n", {})
            ok(r.stdout == "abc\n", "cat echoes small input")
            local big = B.run({"cat"}, BIG, {})
            ok(big.stdout == BIG, "cat echoes 340 KB input")
        end)
    else
        print("note: no stdin capability, stdin checks skipped")
    end

    test("stderr", function()
        local r = B.run({"sh", "-c", "echo out; echo err >&2"}, "", {})
        if caps.separate_stderr then
            ok(r.stdout == "out\n", "stdout holds out")
            ok(r.stderr == "err\n", "stderr holds err")
        else
            local has_out = r.stdout:find("out", 1, true) ~= nil
            local has_err = r.stdout:find("err", 1, true) ~= nil
            ok(has_out and has_err, "both lines merged into stdout")
            ok(r.stderr == "", "stderr empty when merged")
        end
    end)

    if caps.exitcode then
        test("exit status", function()
            local r = B.run({"sh", "-c", "exit 3"}, "", {})
            ok(r.exitcode == 3, "exit 3 is reported")
        end)
    end

    test("missing program", function()
        local r = B.run({"luash-no-such-program-xyz"}, "", {})
        if caps.exitcode then ok(r.exitcode == 127, "exitcode is 127") end
        if caps.separate_stderr then
            ok(r.stderr ~= "", "stderr names the problem")
            ok(r.stdout == "", "stdout is empty")
        else
            ok(r.stdout ~= "", "the shell's message is in stdout")
        end
    end)

    test("streaming callbacks", function()
        local r, out, err = run_collecting(
            B, {"sh", "-c", "printf 'a\\rb\\r'; printf 'x\\n' >&2"}
        )
        ok(out == r.stdout, "stdout chunks equal stdout")
        ok(err == r.stderr, "stderr chunks equal stderr")
        if caps.separate_stderr then
            ok(r.stdout == "a\rb\r", "carriage returns pass through")
            ok(r.stderr == "x\n", "stderr bytes pass through")
        end
        local r2, out2, err2, n = run_collecting(B, {"seq", "1", "20000"})
        ok(out2 == r2.stdout, "seq stdout chunks equal stdout")
        ok(err2 == r2.stderr, "seq stderr chunks equal stderr")
        ok(#r2.stdout > 100000, "seq output exceeds one chunk")
        if caps.streaming then ok(n > 1, "more than one stdout chunk") end
    end)

    test("killed child", function()
        local r = B.run({"sh", "-c", "kill -9 $$"}, "", {})
        if caps.signals then
            ok(r.cause == "killed", "cause is killed")
            ok(r.signal == 9, "signal is 9")
            ok(r.exitcode == 127, "exitcode is 127 for a killed child")
        else
            ok(r.cause == "exited", "cause is exited without signal support")
            if caps.exitcode then
                ok(r.exitcode == 137, "exit status is 128 + 9")
            end
        end
    end)

    test("argument fidelity", function()
        local argv = {
            "printf", "%s\\n",
            "a b", "it's", "", "--", "$HOME", "*", "a;b", "`x`",
        }
        local r = B.run(argv, "", {})
        ok(
            r.stdout == "a b\nit's\n\n--\n$HOME\n*\na;b\n`x`\n",
            "arguments arrive verbatim"
        )
    end)

    test("cwd option", function()
        local r = B.run({"pwd"}, "", { cwd = "/" })
        ok(r.stdout == "/\n", "pwd runs in /")
    end)

    -- posix and luv move the process; the test moves it back.
    test("chdir and getcwd", function()
        local start = B.getcwd()
        ok(type(start) == "string" and start ~= "", "getcwd gives a path")
        local done, err = pcall(function()
            ok(B.chdir("/") == true, "chdir / succeeds")
            ok(B.getcwd() == "/", "getcwd follows chdir")
            local r = B.run({"pwd", "-P"}, "", {})
            ok(r.stdout == "/\n", "run enters the directory")
            r = B.run({"pwd", "-P"}, "", { cwd = start })
            ok(r.stdout == start .. "\n", "the cwd option takes precedence")
            local moved, why = B.chdir("/luash-no-such-directory")
            ok(moved == nil and type(why) == "string", "missing: nil, reason")
            ok(B.getcwd() == "/", "unchanged after a failed chdir")
        end)
        ok(B.chdir(start) == true, "chdir back")
        ok(B.getcwd() == start, "getcwd is back")
        if not done then error(err, 0) end
    end)

    test("argument validation", function()
        ok(not pcall(B.run, {}, "", {}), "empty argv raises")
        ok(not pcall(B.run, {"echo", 1}, "", {}), "non-string element raises")
    end)
end

--------------------------------------------------------------------------------
-- SCRIPT MODE
--------------------------------------------------------------------------------
local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Whether io.popen alone runs a command line that holds input and 8 KiB
-- more. The 8 KiB covers what basic adds around the input and the margin
-- the backend keeps below the system's limit.
local function system_accepts(input)
    local cmd = (
        "printf '%s' " .. quote(input) .. " | wc -c # "
        .. string.rep("x", 8192)
    )
    local h = io.popen(cmd, "r")
    if not h then return false end
    local out = h:read("*a") or ""
    h:close()
    return tonumber(out:match("%d+")) == #input
end

local function main(name, strategy)
    if not name then
        io.stderr:write(
            "usage: lua tests/test_backend.lua <posix|luv|popen|fake> [strategy]\n"
        )
        os.exit(2)
    end
    local modname = "sh.backend." .. name
    if name == "fake" then modname = "backend_fake" end
    local loaded, B = pcall(require, modname)
    if not loaded then
        print("FAIL: cannot load " .. modname .. ": " .. tostring(B))
        os.exit(1)
    end
    if strategy then B.configure({ strategy = strategy }) end
    local available, reason = B.available()
    if not available then
        print(
            "SKIP: backend " .. name .. " unavailable: " .. tostring(reason)
        )
        os.exit(0)
    end

    local passed, failed = 0, 0
    -- checks that may fail: test name -> start of the message
    local allowed = {}
    test(function(e, t, msg)
        local prefix = allowed[t]
        if e == "pass" then
            passed = passed + 1
            print("\27[32m✔\27[0m " .. t .. ": " .. msg)
        elseif e == "fail" and prefix and msg:sub(1, #prefix) == prefix then
            print("note: allowed to fail here: " .. t .. ": " .. msg)
        elseif e == "fail" or e == "except" then
            failed = failed + 1
            print("\27[31m✘\27[0m " .. t .. ": " .. msg)
        end
    end)

    -- popen's basic puts the input on the command line, which Linux caps
    -- at 32 pages per argument (128 KiB with 4 KiB pages). The 340 KB
    -- check may fail for basic, but only where io.popen alone cannot run
    -- a command line that long; tests/test_popen.lua checks that the
    -- backend then reports a start failure.
    local basic = (name == "popen" and B.capabilities().strategy == "basic")
    if basic and not system_accepts(BIG) then
        allowed.stdin = "cat echoes 340 KB input: "
    end

    run_contract(B, name, strategy)

    local label = strategy and (name .. "/" .. strategy) or name
    print(("%d passed, %d failed (backend %s)"):format(passed, failed, label))
    os.exit(failed == 0 and 0 or 1)
end

if arg and arg[0] and arg[0]:match("test_backend%.lua$") then
    main(arg[1], arg[2])
end

return run_contract
