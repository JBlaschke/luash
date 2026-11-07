---@diagnostic disable: undefined-global, redefined-local
-- Tests of the io.popen backend, sh/backend/popen.lua: the backend
-- contract for every available strategy, the shell strings it builds, its
-- private temp directory and the status file.
--
--     lua tests/test_popen.lua
--
-- Prints "SKIP: <reason>" and exits 0 when io.popen is unsupported. Exits
-- 1 when a check fails.

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

local here = init()

do
    local works, h = pcall(io.popen, "exit 0", "r")
    if not (works and h) then
        print("SKIP: io.popen is not supported by this interpreter")
        os.exit(0)
    end
    h:close()
end

--------------------------------------------------------------------------------
-- INITIALIZE TEST HARNESS
--------------------------------------------------------------------------------
local test = require("gambiarra")

local passed, failed = 0, 0
test(function(e, t, msg)
    if e == "pass" then
        passed = passed + 1
        print("\27[32m✔\27[0m " .. t .. ": " .. msg)
    elseif e == "fail" or e == "except" then
        failed = failed + 1
        print("\27[31m✘\27[0m " .. t .. ": " .. msg)
    end
end)

local B            = require("sh.backend.popen")
local run_contract = require("test_backend")

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local MARKER = "^%.luash%-%x+$"   -- the marker file in the private directory

local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function succeeded(r)
    return r == true or r == 0
end

-- stdout of a shell command
local function capture(cmd)
    local h   = assert(io.popen(cmd, "r"))
    local out = h:read("*a") or ""
    h:close()
    return out
end

-- the names in a directory, sorted as ls sorts them
local function entries(dir)
    local names = {}
    for name in capture("ls -A " .. quote(dir)):gmatch("[^\n]+") do
        names[#names + 1] = name
    end
    return names
end

-- the names in the private directory other than the marker
local function temp_files(dir)
    local names = {}
    for _, name in ipairs(entries(dir)) do
        if not name:match(MARKER) then names[#names + 1] = name end
    end
    return names
end

-- ls output without dot files, which BSD ls lists for root
local function visible(listing)
    local lines = {}
    for line in listing:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "." then lines[#lines + 1] = line .. "\n" end
    end
    return table.concat(lines)
end

local function contains(list, x)
    for _, v in ipairs(list) do
        if v == x then return true end
    end
    return false
end

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function is_dir(path)
    return succeeded(os.execute("[ -d " .. quote(path) .. " ]"))
end

local function one_line(s)
    return (s:gsub("\n", " "))
end

-- The interpreter running this file: the lowest index of arg, which is
-- arg[-1] only when no option precedes the script.
local function interpreter()
    if type(arg) ~= "table" then return nil end
    local i = -1
    while arg[i - 1] do
        i = i - 1
    end
    return arg[i]
end

-- Runs the Lua lines in a new interpreter with B loaded, the environment
-- assignments env_prefix in front ("NAME=value ..."); returns its output.
local function run_child(env_prefix, lines)
    local repo  = here .. "/.."
    local paths = repo .. "/?.lua;" .. repo .. "/?/init.lua;"
    local code  = table.concat({
        "package.path = " .. string.format("%q", paths) .. " .. package.path",
        "local B = require('sh.backend.popen')",
        table.concat(lines, "\n"),
    }, "\n")
    return capture(
        env_prefix .. quote(interpreter()) .. " -e " .. quote(code) .. " 2>&1"
    )
end

-- A scratch directory for this run, removed at the end: shell strings for
-- shellcheck go there, root/ serves as a configured tmpdir, and child/ and
-- fallback/ as temp roots of child interpreters.
local function make_scratch()
    local base = os.getenv("TMPDIR") or ""
    if base == "" then base = "/tmp" end
    base = base:gsub("/+$", "")
    local digits = tostring({}):gsub("%D", "")
    local dir    = base .. "/luash-test-" .. os.time() .. "-" .. digits
    local names  = {
        "", "/root", "/child", "/fallback", "/pid", "/hooked", "/real",
        "/real/a"
    }
    local args   = {}
    for i, name in ipairs(names) do
        args[i] = quote(dir .. name)
    end
    local made = os.execute("mkdir -m 700 " .. table.concat(args, " "))
    assert(succeeded(made), "cannot create the scratch directory " .. dir)
    return dir
end

local scratch  = make_scratch()
local root     = scratch .. "/root"
local child    = scratch .. "/child"
local fallback = scratch .. "/fallback"

-- what h:close() of this interpreter reports, found without the backend
local close_status
do
    local h = assert(io.popen("exit 7", "r"))
    local _, _, code = h:close()
    close_status = (code == 7)
end

-- Shell strings of handoff/DESIGN.md section 6.3, rendered for POSIX sh,
-- in the form the header of sh/backend/popen.lua explains.
local FILES = { input = "/t/in-1", stderr = "/t/err-1", status = "/t/st-1" }
local FILE_FORM =
    [[{ set +eux; } 2>/dev/null; unset -f cd echo printf; ( ( cd -P '/w' || exit 127; exec 'a b' 'it'\''s' ) < '/t/in-1' 2> '/t/err-1' 3>&-; echo "$?" >&3 ) 2>/dev/null 3> '/t/st-1']]
local NO_INPUT_FORM =
    [[{ set +eux; } 2>/dev/null; unset -f cd echo printf; ( ( exec 'pwd' ) < /dev/null 2> '/t/err-2' 3>&-; echo "$?" >&3 ) 2>/dev/null 3> '/t/st-2']]
local MINIMAL_FORM =
    [[{ set +eux; } 2>/dev/null; unset -f cd echo printf; ( ( exec 'sort' '-r' ) < /dev/null 2>&1; exit $? ) 2>/dev/null]]
local BASIC_FORM =
    [[{ set +eux; } 2>/dev/null; unset -f cd echo printf; { trap '' PIPE; printf '%s' 'it'\''s' || :; } 2>/dev/null | ( ( cd -P './w' || exit 127; exec 'cat' ) 2>&1; exit $? ) 2>/dev/null]]
local BASIC_NUL_FORM =
    [[{ set +eux; } 2>/dev/null; unset -f cd echo printf; { trap '' PIPE; printf '%b' 'a\0000b\\c\0200\0377' || :; } 2>/dev/null | ( ( cd -P './-' || exit 127; exec 'cat' ) 2>&1; exit $? ) 2>/dev/null]]

--------------------------------------------------------------------------------
-- CONTRACT, ONCE PER STRATEGY
--------------------------------------------------------------------------------
local strategies = B.available_strategies()
print("available strategies: " .. table.concat(strategies, " "))

-- The contract sends 340 KB of input through cat. basic puts the input on
-- the command line, which Linux caps at 128 KiB per argument.
local contract_skip = {}
if contains(strategies, "basic") then
    B.configure({ strategy = "basic" })
    local input = string.rep("0123456789abcdef\n", 20000)
    local r     = B.run({"cat"}, input, {})
    if r.cause == "failed" then
        contract_skip.basic = one_line(r.stderr)
    end
end

for _, s in ipairs(strategies) do
    B.configure({ strategy = s })
    if contract_skip[s] then
        print("note: contract for " .. s .. " skipped: " .. contract_skip[s])
    else
        run_contract(B, "popen", s)
    end
end
B.configure({})

--------------------------------------------------------------------------------
-- STRATEGIES AND CAPABILITIES
--------------------------------------------------------------------------------
test("strategies and capabilities", function()
    ok(
        contains(strategies, "basic") and contains(strategies, "minimal"),
        "basic and minimal are always available"
    )
    for _, s in ipairs(strategies) do
        B.configure({ strategy = s })
        local caps  = B.capabilities()
        local files = (s == "shmem" or s == "standard")
        ok(caps.strategy == s, s .. ": capabilities().strategy")
        ok(caps.stdin == (s ~= "minimal"), s .. ": stdin")
        ok(caps.separate_stderr == files, s .. ": separate_stderr")
        ok(
            caps.exitcode == (files or close_status),
            s .. ": exitcode is " .. tostring(files or close_status)
        )
        ok(caps.streaming and not caps.signals, s .. ": streaming, signals")
    end
    B.configure({})
    ok(
        B.capabilities().strategy == strategies[1],
        "auto picks the first available strategy, " .. strategies[1]
    )
    B.configure({ tmpdir = root })
    ok(
        B.capabilities().strategy == "standard",
        "auto with a configured tmpdir picks standard, not shmem"
    )
    ok(
        not pcall(B.configure, { strategy = "bogus" }),
        "an unknown strategy raises"
    )
    ok(not pcall(B.configure, { tmpdir = 5 }), "a tmpdir not a string raises")
    B.configure({})
end)

test("minimal and basic", function()
    B.configure({ strategy = "minimal" })
    local raised, err = pcall(B.run, {"cat"}, "x", {})
    ok(
        not raised and tostring(err):find(
            "sh.popen: strategy minimal cannot pass input to cat", 1, true
        ) ~= nil,
        "minimal raises on input"
    )
    ok(B.run({"cat"}, "", {}).stdout == "", "minimal: stdin is /dev/null")

    B.configure({ strategy = "basic" })
    local input = "it's\n'' $HOME `x` \\n\n"
    ok(
        B.run({"cat"}, input, {}).stdout == input,
        "basic passes quotes, backslashes and newlines in the input"
    )
    local binary = "a\0b\\0000c\\\0\0001\n"
    ok(
        B.run({"cat"}, binary, {}).stdout == binary,
        "basic passes NUL bytes and backslashes next to them"
    )
    local bytes = {}
    for i = 0, 255 do
        bytes[#bytes + 1] = string.char(i) .. "\\" .. string.char(i)
    end
    bytes = table.concat(bytes)
    ok(
        B.run({"cat"}, bytes, {}).stdout == bytes,
        "basic passes every byte value, each before a backslash"
    )
    local r = B.run({"sh", "-c", "exit 3"}, "", {})
    if close_status then
        ok(r.exitcode == 3, "basic: exit status from h:close()")
    else
        ok(r.exitcode == 0, "basic: exitcode 0 where close() reports none")
        print("note: h:close() reports no exit status on this interpreter")
    end

    -- far above ARG_MAX on every system: a start failure, not a hang or a
    -- silent empty result
    local errs = {}
    local huge = B.run({"cat"}, string.rep("x", 3 * 1024 * 1024), {
        on_stderr = function(chunk) errs[#errs + 1] = chunk end,
    })
    ok(
        huge.cause == "failed" and huge.exitcode == 127
        and huge.stdout == "",
        "basic: 3 MiB of input is a start failure"
    )
    ok(
        huge.stderr:find("longer than the system accepts", 1, true) ~= nil
        and table.concat(errs) == huge.stderr,
        "basic: stderr says why: " .. one_line(huge.stderr)
    )
    B.configure({})
end)

--------------------------------------------------------------------------------
-- SHELL STRINGS
--------------------------------------------------------------------------------
test("shell strings", function()
    local s = B._render({"a b", "it's"}, FILES, "/w", "sh")
    ok(s == FILE_FORM, "file strategy string")
    local no_input = B._render(
        {"pwd"}, { stderr = "/t/err-2", status = "/t/st-2" }, nil, "sh"
    )
    ok(no_input == NO_INPUT_FORM, "a file strategy without input")
    local minimal = B._render({"sort", "-r"}, nil, nil, "sh")
    ok(minimal == MINIMAL_FORM, "minimal string")
    local basic = B._render({"cat"}, { data = "it's" }, "w", "sh")
    ok(basic == BASIC_FORM, "basic string, relative cwd gets ./")
    local nul = B._render({"cat"}, { data = "a\0b\\c\128\255" }, "-", "sh")
    ok(
        nul == BASIC_NUL_FORM,
        "basic string for input with a NUL byte: bytes from 0x80 in octal"
    )
    local dashed = B._render({"-x/prog"}, nil, nil, "sh")
    ok(
        dashed:find("exec './-x/prog' )", 1, true) ~= nil,
        "a program path starting with - gets ./"
    )

    -- Windows: rendered only, never run here
    local cmd = B._render({'say "hi"', "x"}, FILES, "C:\\w", "cmd")
    ok(
        cmd:find([[cd /d "C:\w" && "say ""hi""" "x" < "/t/in-1"]], 1, true)
        ~= nil,
        "cmd variant quotes with doubled double quotes"
    )
    ok(
        B._render({"x"}, nil, nil, "cmd"):find("< NUL 2>&1", 1, true) ~= nil,
        "cmd variant reads NUL"
    )
end)

test("shellcheck", function()
    if capture("command -v shellcheck") == "" then
        print("note: shellcheck is not on PATH, shell strings not checked")
        ok(true, "shellcheck check skipped")
        return
    end
    local cases = {
        { "file",          FILE_FORM      },
        { "file-no-input", NO_INPUT_FORM  },
        { "minimal",       MINIMAL_FORM   },
        { "basic",         BASIC_FORM     },
        { "basic-nul",     BASIC_NUL_FORM },
    }
    for _, case in ipairs(cases) do
        local path = scratch .. "/" .. case[1] .. ".sh"
        write_file(path, "#!/bin/sh\n" .. case[2] .. "\n")
        ok(
            succeeded(os.execute("shellcheck -s sh " .. quote(path))),
            "shellcheck -s sh accepts the " .. case[1] .. " string"
        )
    end
end)

--------------------------------------------------------------------------------
-- PROGRAM LOOKUP, ARGUMENTS AND CWD
--------------------------------------------------------------------------------
test("program lookup", function()
    B.configure({ strategy = "standard", tmpdir = root })
    -- a shell builtin would exit 5; exec finds no program `exit` on PATH
    local r = B.run({"exit", "5"}, "", {})
    ok(
        r.exitcode == 127 and r.stderr ~= "",
        "argv[1] is never a shell builtin: exit 5 gives 127, "
        .. one_line(r.stderr)
    )
    ok(
        B.run({"echo", "-n", "x"}, "", {}).stdout == "x",
        "echo -n x prints x (macOS sh's builtin echo would print -n x)"
    )
    local script = scratch .. "/not-executable"
    write_file(script, "#!/bin/sh\necho hi\n")
    r = B.run({script}, "", {})
    ok(
        r.exitcode == 127 and r.cause == "exited" and r.stdout == ""
        and r.stderr ~= "",
        "a program that is not executable gives 127: " .. one_line(r.stderr)
    )
    r = B.run({"-c", "true"}, "", {})
    ok(
        r.cause == "failed" and r.exitcode == 127,
        "a program name starting with - is a start failure: "
        .. one_line(r.stderr)
    )
    local raised, err = pcall(B.run, {"echo", "a\0b"}, "", {})
    ok(
        not raised and tostring(err):find("NUL", 1, true) ~= nil,
        "a NUL byte in argv raises: " .. tostring(err)
    )
    local big = string.rep("0123456789abcdef", 3 * 65536)
    ok(
        B.run({"cat"}, big, {}).stdout == big,
        "standard: 3 MiB of input through the input file"
    )
    B.configure({})
end)

test("cwd", function()
    B.configure({ strategy = "standard", tmpdir = root })
    local missing = "/nonexistent/luash-x"
    local r = B.run({"pwd"}, "", { cwd = missing })
    ok(
        r.exitcode == 127 and r.stdout == ""
        and r.stderr:find(missing, 1, true) ~= nil,
        "a missing cwd gives 127 and the shell's message: "
        .. one_line(r.stderr)
    )
    -- link -> real/a, so link/.. is real for chdir() and scratch for a
    -- logical cd
    os.execute(
        "ln -s " .. quote(scratch .. "/real/a") .. " "
        .. quote(scratch .. "/link")
    )
    local physical = capture("cd -P " .. quote(scratch .. "/real") .. " && pwd")
    r = B.run({"pwd", "-P"}, "", { cwd = scratch .. "/link/.." })
    ok(
        r.stdout == physical,
        "cwd with .. after a symlink is resolved like chdir(): "
        .. one_line(r.stdout)
    )
    r = B.run({"pwd"}, "", { cwd = "" })
    ok(
        r.cause == "failed" and r.exitcode == 127,
        "an empty cwd is a start failure: " .. one_line(r.stderr)
    )
    local raised, err = pcall(B.run, {"pwd"}, "", { cwd = "/\0" })
    ok(not raised, "a NUL byte in cwd raises: " .. tostring(err))
    B.configure({})
end)

--------------------------------------------------------------------------------
-- PRIVATE DIRECTORY AND STATUS FILE
--------------------------------------------------------------------------------
local private   -- the private directory under root, found by the next test

-- the one luash-<pid>-<random> directory under root, or nil
local function only_private_dir()
    local names = entries(root)
    if #names == 1 and names[1]:match("^luash%-%d+%-%d+$") then
        return root .. "/" .. names[1]
    end
    return nil
end

test("private directory", function()
    B.configure({ strategy = "standard", tmpdir = root })
    B.cleanup_all()
    local r = B.run({"cat"}, "x", {})
    ok(r.stdout == "x", "standard run with a configured tmpdir")
    private = only_private_dir()
    ok(
        private ~= nil,
        "one directory luash-<pid>-<random> in the temp root: "
        .. table.concat(entries(root), " ")
    )
    private = private or root .. "/missing"
    local mode = capture("ls -ld " .. quote(private)):sub(1, 10)
    ok(mode == "drwx------", "ls -ld shows drwx------: " .. mode)
    ok(
        #temp_files(private) == 0,
        "no in-*, err-* or st-* files left behind"
    )
    local names = entries(private)
    ok(
        #names == 1 and names[1]:match(MARKER) ~= nil,
        "the marker .luash-<hex> is all that stays in it: "
        .. table.concat(names, " ")
    )

    B.cleanup_all()
    ok(#entries(root) == 0, "cleanup_all() removes the private directory")
    B.run({"true"}, "", {})
    private = only_private_dir()
    ok(private ~= nil, "the next run recreates it")
    private = private or root .. "/missing"
    B.configure({})
end)

test("vanished or replaced private directory", function()
    B.configure({ strategy = "standard", tmpdir = root })
    -- a temp cleaner removed it
    os.execute("rm -rf " .. quote(private))
    local r = B.run({"cat"}, "x", {})
    ok(
        r.stdout == "x" and r.exitcode == 0 and r.stderr == "",
        "a run after the directory vanished works"
    )
    local renewed = only_private_dir()
    ok(renewed ~= nil, "and makes a new directory")
    renewed = renewed or root .. "/missing"

    -- someone made a directory of the same name: never write into it
    os.execute("rm -rf " .. quote(renewed))
    os.execute("mkdir -m 700 " .. quote(renewed))
    r = B.run({"cat"}, "y", {})
    ok(r.stdout == "y" and r.exitcode == 0, "a run after it was replaced")
    ok(#entries(renewed) == 0, "the stranger's directory stays untouched")
    local names = entries(root)
    ok(#names == 2, "the run made a directory of its own")
    B.cleanup_all()
    ok(
        is_dir(renewed) and #entries(root) == 1,
        "cleanup_all() removes its own directory, not the stranger's"
    )
    os.execute("rmdir " .. quote(renewed))

    B.run({"true"}, "", {})
    private = only_private_dir() or root .. "/missing"
    B.configure({})
end)

test("file names and status file", function()
    B.configure({ strategy = "standard", tmpdir = root })
    -- `ls` sees the files of its own run: err-<n> and st-<n>, which the
    -- shell opened, and in-<n>
    local pattern    = "^err%-(%d+)\nin%-(%d+)\nst%-(%d+)\n$"
    local first      = visible(B.run({"ls", private}, "x", {}).stdout)
    local second     = visible(B.run({"ls", private}, "x", {}).stdout)
    local e1, n1, s1 = first:match(pattern)
    local e2, n2, s2 = second:match(pattern)
    ok(
        n1 ~= nil and e1 == n1 and s1 == n1 and e2 == n2 and s2 == n2,
        "a run has err-<n>, in-<n> and st-<n>: " .. one_line(first)
    )
    ok(
        n1 ~= nil and n2 ~= nil and tonumber(n2) > tonumber(n1),
        "the next run uses new names (counter advances): "
        .. tostring(n1) .. " then " .. tostring(n2)
    )
    ok(#temp_files(private) == 0, "both runs removed their files")

    local r = B.run({"sh", "-c", "exit 3"}, "", {})
    ok(r.exitcode == 3, "sh -c 'exit 3' gives exitcode 3")
    if not close_status then
        print(
            "note: h:close() reports no exit status on this interpreter;"
            .. " the status file supplied it"
        )
    end

    local raised, err = pcall(B.run, {"echo", "hi"}, "x", {
        on_stdout = function() error("boom from on_stdout") end,
    })
    ok(
        not raised and tostring(err):find("boom from on_stdout", 1, true)
        ~= nil,
        "an error raised by on_stdout propagates"
    )
    ok(#temp_files(private) == 0, "and the run's files are still removed")

    -- The program replaces the private directory while it runs, with
    -- st-<n> a symlink to a victim file and err-<n> holding a fake
    -- message. The shell opened its status file before the program
    -- started, and the run reads nothing from a directory without its
    -- marker.
    local n      = tonumber(visible(
        B.run({"ls", private}, "x", {}).stdout
    ):match("^err%-(%d+)")) or 0
    local victim = scratch .. "/victim"
    write_file(victim, "victim\n")
    r = B.run({
        "sh", "-c",
        'rm -rf "$1"; mkdir -m 700 "$1"; ln -s "$2" "$1/st-$3";'
        .. ' printf fake > "$1/err-$3"; exit 5',
        "sh", private, victim, tostring(n + 1),
    }, "", {})
    ok(
        read_file(victim) == "victim\n",
        "a planted st-<n> symlink is not written through"
    )
    ok(
        r.exitcode == 127 and r.stderr:find("fake", 1, true) == nil
        and r.stderr:find("vanished", 1, true) ~= nil,
        "the stranger's files are not read: " .. one_line(r.stderr)
    )
    ok(
        read_file(private .. "/err-" .. (n + 1)) == "fake",
        "nor removed"
    )
    os.execute("rm -rf " .. quote(private))
    B.run({"true"}, "", {})
    private = only_private_dir() or root .. "/missing"
    B.configure({})
end)

--------------------------------------------------------------------------------
-- FAILURES
--------------------------------------------------------------------------------
test("start failure", function()
    -- io.popen returning nil (EMFILE, E2BIG) is a start failure, reported
    -- like a program that cannot be started
    for _, s in ipairs({ "standard", "minimal" }) do
        B.configure({ strategy = s, tmpdir = root })
        local real = io.popen
        local errs = {}
        io.popen = function(cmd)
            return nil, cmd .. ": Too many open files"
        end
        local ran, r = pcall(B.run, {"echo", "hi"}, "", {
            on_stderr = function(chunk) errs[#errs + 1] = chunk end,
        })
        io.popen = real
        ok(ran, s .. ": run returns a result")
        if ran then
            ok(
                r.cause == "failed" and r.exitcode == 127 and r.signal == 0,
                s .. ": cause failed, exitcode 127"
            )
            ok(
                r.stderr == "sh.popen: echo: Too many open files\n",
                s .. ": stderr names the program and the reason"
            )
            ok(table.concat(errs) == r.stderr, s .. ": on_stderr got it")
        end
    end
    ok(#temp_files(private) == 0, "no files left after a start failure")
    B.configure({})
end)

test("pid in the directory name", function()
    -- a new copy of the module, which has not asked for the pid yet
    local name = "sh.backend.popen"
    package.loaded[name] = nil
    local fresh = require(name)
    package.loaded[name] = B
    local dir = scratch .. "/pid"
    fresh.configure({ strategy = "standard", tmpdir = dir })

    -- io.popen fails once, for `echo $$` alone
    local real = io.popen
    io.popen = function(cmd, mode)
        if cmd:find("echo $$", 1, true) then
            return nil, cmd .. ": Too many open files"
        end
        return real(cmd, mode)
    end
    local ran, r = pcall(fresh.run, {"true"}, "", {})
    io.popen = real
    local first = entries(dir)
    fresh.cleanup_all()
    fresh.run({"true"}, "", {})
    local second = entries(dir)
    fresh.cleanup_all()
    ok(
        ran and r.exitcode == 0 and #first == 1
        and first[1]:match("^luash%-%d+$") ~= nil,
        "no pid in the name while io.popen fails: " .. table.concat(first, " ")
    )
    ok(
        #second == 1 and second[1]:match("^luash%-%d+%-%d+$") ~= nil,
        "the pid is asked again later: " .. table.concat(second, " ")
    )
end)

test("undefined globals", function()
    -- sh.install() gives _G an __index that makes every undefined global
    -- a command function. A copy of the module loaded and run under such
    -- a hook must not take one for an optional global such as newproxy
    -- (undefined from Lua 5.2 on).
    local name   = "sh.backend.popen"
    local gmt    = getmetatable(_G)
    local called = {}
    setmetatable(_G, { __index = function(_, key)
        return function()
            called[#called + 1] = tostring(key)
            error("the undefined global " .. tostring(key) .. " was called")
        end
    end })
    package.loaded[name] = nil
    local loaded, fresh = pcall(require, name)
    local ran, r = false, nil
    if loaded then
        local dir = scratch .. "/hooked"
        fresh.configure({ strategy = "standard", tmpdir = dir })
        ran, r = pcall(fresh.run, {"true"}, "", {})
        fresh.cleanup_all()
    end
    setmetatable(_G, gmt)
    package.loaded[name] = B
    ok(
        loaded and ran and r.exitcode == 0 and #called == 0,
        "loads and runs; globals called: [" .. table.concat(called, " ")
        .. "] " .. (ran and "" or tostring(r or fresh))
    )
end)

test("temp directory failures", function()
    -- a configured tmpdir that does not exist: unavailable, and run
    -- returns a start failure instead of raising
    local missing = "/nonexistent/luash-x"
    B.configure({ strategy = "standard", tmpdir = missing })
    local available, why = B.available()
    ok(
        available == false and tostring(why):find(missing, 1, true) ~= nil,
        "available() is false and names the tmpdir: " .. tostring(why)
    )
    local ran, r = pcall(B.run, {"true"}, "", {})
    ok(
        ran and r.cause == "failed" and r.exitcode == 127
        and r.stderr:find(missing, 1, true) ~= nil,
        "run returns a start failure: "
        .. (ran and one_line(r.stderr) or tostring(r))
    )

    -- the input file cannot be written
    if capture("id -u"):match("%d+") == "0" then
        print("note: running as root, the read-only directory check skipped")
        ok(true, "read-only check skipped")
    else
        B.configure({ strategy = "standard", tmpdir = root })
        os.execute("chmod 500 " .. quote(private))
        ran, r = pcall(B.run, {"cat"}, "x", {})
        os.execute("chmod 700 " .. quote(private))
        ok(
            ran and r.cause == "failed" and r.exitcode == 127
            and r.stderr:find("cannot write", 1, true) ~= nil,
            "an input file that cannot be written is a start failure: "
            .. (ran and one_line(r.stderr) or tostring(r))
        )
    end
    B.configure({})
end)

--------------------------------------------------------------------------------
-- CHILD INTERPRETERS: ENVIRONMENT AND STATE CLOSE
--------------------------------------------------------------------------------
test("child interpreters", function()
    if not interpreter() then
        print("note: interpreter path unknown, child checks skipped")
        ok(true, "child checks skipped")
        return
    end
    local tmp = string.format("%q", child)

    -- The child ends normally, so lua_close runs the finalizer, which
    -- removes the private directory.
    local out = run_child("", {
        "B.configure({ strategy = 'standard', tmpdir = " .. tmp .. " })",
        "io.write(B.run({'ls', " .. tmp .. "}, '', {}).stdout)",
    })
    ok(
        out:match("^luash%-%d+%-%d+\n$") ~= nil,
        "the child made a private directory: " .. one_line(out)
    )
    ok(
        #entries(child) == 0,
        "the finalizer removed it when the child's state closed"
    )

    -- Exported bash functions replace builtins and programs in a /bin/sh
    -- that is bash (macOS); dash ignores them.
    out = run_child(
        "env 'BASH_FUNC_echo%%=() { builtin echo 0; }'"
        .. " 'BASH_FUNC_cd%%=() { builtin cd \"$@\" && builtin echo cd; }'"
        .. " 'BASH_FUNC_mkdir%%=() { return 0; }'"
        .. " 'BASH_FUNC_test%%=() { return 1; }' ",
        {
            "B.configure({ strategy = 'standard', tmpdir = " .. tmp .. " })",
            "local r = B.run({'sh', '-c', 'exit 3'}, '', { cwd = '/' })",
            "local p = B.run({'pwd'}, '', { cwd = '/' })",
            "io.write(r.exitcode, ' ', p.stdout)",
        }
    )
    ok(
        out == "3 /\n",
        "exported functions named echo, cd, mkdir and test change nothing: "
        .. one_line(out)
    )

    -- bash as /bin/sh also takes options from an exported SHELLOPTS:
    -- errexit would end the shell before it writes the status, pipefail
    -- would report the SIGPIPE of printf, whose input true does not read,
    -- and xtrace would write into the captured stderr and the child's own.
    out = run_child("env SHELLOPTS=errexit:nounset:pipefail:xtrace ", {
        "B.configure({ strategy = 'standard', tmpdir = " .. tmp .. " })",
        "local r = B.run({'cat', '/nonexistent/luash-x'}, '', {})",
        "B.configure({ strategy = 'basic' })",
        "local b = B.run({'true'}, string.rep('x', 70000), {})",
        "io.write(r.exitcode, ' ', r.stderr, b.exitcode, ' ', b.stdout)",
    })
    ok(
        out:match("^1 cat: [^\n]*\n0 $") ~= nil,
        "an exported SHELLOPTS changes nothing: " .. one_line(out)
    )

    -- The environment takes room on the exec line as well (on macOS from
    -- ARG_MAX): with 200 KB of it, a command line that fits ARG_MAX less
    -- 64 KiB is still a start failure, not a run without exit status.
    -- Two variables, since Linux caps each at 128 KiB like an argument.
    local arg_max = tonumber(
        capture("getconf ARG_MAX 2>/dev/null"):match("%d+") or ""
    )
    if arg_max and arg_max <= 4 * 1024 * 1024 then
        local big = '"$(printf %0100000d 0)" '
        out = run_child("BIG1=" .. big .. "BIG2=" .. big, {
            "B.configure({ strategy = 'standard', tmpdir = " .. tmp .. " })",
            "local n = " .. (arg_max - 65536 - 20000),
            "local r = B.run({'true', string.rep('x', n)}, '', {})",
            "io.write(r.cause, ' ', r.exitcode, ' ', r.stderr)",
        })
        ok(
            out:find("^failed 127 sh%.popen: true: the command line") ~= nil,
            "a large environment counts against the limit: " .. one_line(out)
        )
    else
        print("note: ARG_MAX unknown or above 4 MiB, environment check skipped")
        ok(true, "environment check skipped")
    end

    -- A TMPDIR that is not a directory is passed over for the next
    -- candidate (TMP, TEMP, /tmp). os.exit skips the state close, so the
    -- private directory stays for the check.
    out = run_child(
        "TMPDIR=/nonexistent/luash-x TMP= TEMP=" .. quote(fallback) .. " ",
        {
            "B.configure({ strategy = 'standard' })",
            "local r = B.run({'true'}, '', {})",
            "io.write(r.cause, ' ', r.exitcode, ' ', r.stderr)",
            "os.exit(0)",
        }
    )
    ok(out == "exited 0 ", "a run with a stale TMPDIR succeeds: " .. out)
    local names = entries(fallback)
    ok(
        #names == 1 and names[1]:match("^luash%-%d+%-%d+$") ~= nil,
        "its private directory is under TEMP: " .. table.concat(names, " ")
    )
end)

test("shmem", function()
    local system = capture("uname -s"):gsub("%s+$", "")
    local has    = contains(strategies, "shmem")
    if system == "Darwin" then
        ok(not has, "shmem is not available on macOS")
        print("note: macOS has no /dev/shm, so strategy shmem is unavailable")
        B.configure({ strategy = "shmem" })
        local available, why = B.available()
        ok(
            available == false and type(why) == "string",
            "available() is false with a reason: " .. tostring(why)
        )
        B.configure({})
    else
        print(
            "note: strategy shmem is " .. (has and "" or "not ")
            .. "available on " .. system
        )
        ok(true, "shmem availability reported")
    end
end)

--------------------------------------------------------------------------------
-- CLEAN UP AND REPORT
--------------------------------------------------------------------------------
B.cleanup_all()
os.execute("rm -rf " .. quote(scratch))

print(("%d passed, %d failed (popen backend)"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
