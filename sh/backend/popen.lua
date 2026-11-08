-- Process backend on io.popen, for interpreters that have neither
-- luaposix nor luv (docs/DESIGN.md sections 4, 5 and 6.3). Standard
-- library only; runs on Lua 5.1 to 5.5 and LuaJIT.
--
-- io.popen gives one pipe: the child's stdout. Strategies supply the rest,
-- from most to least capable:
--
--   shmem     stdin and stderr in temp files in a private directory under
--             /dev/shm (Linux tmpfs); separate stderr, exit status
--   standard  the same under the temp root: configure's tmpdir, else the
--             first writable of TMPDIR, TMP, TEMP and /tmp
--   basic     no temp files: the input goes on the command line as
--             `printf '%s' '<input>' |` and stderr is merged into stdout.
--             Every user of the machine can read that input in `ps`, and
--             the size limit for a command line caps it (128 KiB on
--             Linux, about 1 MiB on macOS). "auto" never picks basic while
--             a file strategy is available.
--   minimal   no temp files, no input (stdin is /dev/null), stderr merged
--
-- /bin/sh runs `exec <argv>` in a subshell, so argv[1] is always the
-- program found on PATH, never a shell builtin or function of that name,
-- and every argument reaches it verbatim (none can carry a NUL byte,
-- which raises). Every shell string first turns off the errexit, nounset
-- and xtrace options that bash as /bin/sh takes from an exported
-- SHELLOPTS, and removes exported bash functions named like the commands
-- it runs (cd, echo, printf, mkdir, rm and others). opts.cwd is entered
-- with `cd -P`, which resolves `..` like chdir() does. A program that
-- cannot be started (not found, not executable, a missing cwd) exits 127
-- with the shell's message on stderr, as from the other backends; a
-- program that exits 126 by itself shows as 127 too. A program name
-- starting with "-" and a command line longer than the system accepts are
-- start failures (cause "failed", exit code 127).
--
-- io.popen has no chdir, so `cd` is emulated: chdir() resolves the
-- directory through the shell (`cd -P ... && pwd -P`), which also checks
-- that it can be entered, and remembers it; run() enters it when opts.cwd
-- is nil, and getcwd() returns it. The emulated directory applies to the
-- programs this backend runs only, not to Lua's own io functions.
--
-- The private directory <root>/luash-<pid>-<random> is made once per
-- process and root with `mkdir -m 700`, which fails when the name exists,
-- so no other user can read it or plant a file or symlink in it. Lua
-- creates a marker file in it whose name, .luash-<32 hex digits from
-- /dev/urandom>, appears on no command line. A run starts only when the
-- marker is there, and reads and removes its files only when it still is:
-- a directory a temp cleaner removed is made again, and one that someone
-- else made under the same name since is never written to or read. Each
-- run writes in-<n> (input), err-<n> (stderr) and st-<n> (exit status)
-- there and removes them afterwards, also when the run raises. The shell
-- opens st-<n> before the program starts. cleanup_all() removes the
-- directory, and a finalizer calls it when the Lua state is closed.
-- os.exit(code) skips that unless its second argument is `true`
-- (honoured from Lua 5.2 and by LuaJIT 2.1, never by Lua 5.1), so a
-- script that ends with os.exit should call cleanup_all() first. A
-- directory left behind (luash-*) is safe to delete.
--
-- Exit status: the file strategies have the shell write it to st-<n>,
-- which works on every interpreter. The merged strategies take it from
-- h:close(), which reports it on Lua 5.2 and newer but not on Lua 5.1 or
-- LuaJIT, where exitcode is 0 and capabilities().exitcode is false. A
-- child killed by signal N shows as exit status 128 + N (signals = false).
--
-- Streaming: stdout reaches on_stdout in blocks of 4096 bytes (stdio's
-- fread fills a block before it returns); stderr reaches on_stderr in one
-- piece after the child has exited.
local M = { name = "popen" }

local ORDER     = { "shmem", "standard", "basic", "minimal" }
local MAX_TRIES = 10
local CHUNK     = 4096
local ARG_SLACK = 65536   -- shorter command lines skip the length check
local NOT_RUN   = 127     -- exit code of a program that was not started

local STRATEGIES = {
    shmem    = { files = true,  stdin = true  },
    standard = { files = true,  stdin = true  },
    basic    = { files = false, stdin = true  },
    minimal  = { files = false, stdin = false },
}

-- "cmd" on Windows (cmd.exe syntax, best effort), "sh" everywhere else
local MODE = package.config:sub(1, 1) == "\\" and "cmd" or "sh"

-- Lua 5.1 and LuaJIT only. rawget: after sh.install(), _G's __index makes
-- an undefined global a command function.
local newproxy = rawget(_G, "newproxy")

local config = { strategy = "auto", tmpdir = nil }

-- The directory chdir() moved to, nil until the first chdir(); run() enters
-- it when opts.cwd is nil (emulated `cd`, see the module comment).
local emulated = nil

local resolved     = nil   -- strategy name that config.strategy resolves to
local probed       = {}    -- root -> result of the writable check
local dirs         = {}    -- root -> { path, marker } in use under it
local made         = {}    -- every { path, marker } made, for cleanup_all
local counter      = 0     -- numbers the temp files of each run
local pid          = nil   -- id of a shell, from `echo $$`; false: none
local seeded       = false
local sentinel     = nil   -- userdata or table whose __gc calls cleanup_all
local popen_ok     = nil   -- io.popen works (cached once known)
local popen_why    = nil
local close_status = nil   -- h:close() reports the exit status
local cmd_limit    = nil   -- longest command line exec takes; false: unknown

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------
local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Every POSIX shell string starts here. bash as /bin/sh takes options from
-- an exported SHELLOPTS and functions from exported BASH_FUNC_<name>%%
-- variables. set turns off errexit, nounset and xtrace, with its own trace
-- sent nowhere, and unset removes functions of the names the string runs;
-- both are special builtins, which no function replaces.
local function sh_line(s, names)
    local line = "{ set +eux; } 2>/dev/null; "
    if names then
        line = line .. "unset -f " .. names .. "; "
    end
    return line .. s
end

-- A probe line for the platform's shell: cmd.exe takes it as it is.
local function probe_line(s)
    if MODE == "sh" then
        return sh_line(s)
    end
    return s
end

local function succeeded(r)
    return r == true or r == 0
end

local function has_nul(s)
    return s:find("%z") ~= nil
end

local function env(name)
    local value = os.getenv(name)
    if value ~= "" then return value end
    return nil
end

local function join(dir, name)
    local last = dir:sub(-1)
    if last == "/" or last == "\\" then return dir .. name end
    if MODE == "cmd" then return dir .. "\\" .. name end
    return dir .. "/" .. name
end

-- stdout of a shell command, or nil when io.popen fails
local function capture(cmd)
    local ok, h = pcall(io.popen, cmd, "r")
    if not (ok and h) then return nil end
    local out = h:read("*a") or ""
    h:close()
    return out
end

local function check_argv(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("sh.popen: argv must be a non-empty array of strings", 3)
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            error("sh.popen: argv[" .. i .. "] is not a string", 3)
        end
        if has_nul(argv[i]) then
            error("sh.popen: argv[" .. i .. "] contains a NUL byte", 3)
        end
    end
end

local function popen_works()
    if popen_ok == nil then
        local ok, h = pcall(io.popen, probe_line("exit 0"), "r")
        if not ok then
            -- interpreters built without popen raise "'popen' not supported"
            popen_ok  = false
            popen_why = "io.popen is not supported by this interpreter"
        elseif h then
            h:close()
            popen_ok = true
        else
            return false, "io.popen failed"
        end
    end
    return popen_ok, popen_why
end

-- h:close() returns true, "exit", code on Lua 5.2 and newer but only true
-- on Lua 5.1 and LuaJIT; a run with a known status tells which.
local function close_reports_status()
    if close_status == nil then
        local ok, h = pcall(io.popen, probe_line("exit 7"), "r")
        if not ok then
            close_status = false
        elseif h then
            local _, _, code = h:close()
            close_status = (code == 7)
        else
            return false   -- io.popen failed for now (EMFILE): ask again
        end
    end
    return close_status
end

local function close_code(how, code)
    if how == "exit" then return code end
    if how == "signal" then return 128 + code end
    return nil
end

-- The shell exits 126 when it finds the program but cannot execute it;
-- posix and luv report that as 127, like a program not found.
local function exit_code(code)
    if code == 126 then return NOT_RUN end
    return code
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- true, or nil and the reason
local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then
        return nil, "cannot write " .. tostring(err)
    end
    local written, werr = f:write(data)
    local closed, cerr  = f:close()
    if not (written and closed) then
        return nil, "cannot write " .. path .. ": " .. tostring(werr or cerr)
    end
    return true
end

--------------------------------------------------------------------------------
-- SHELL STRINGS
--------------------------------------------------------------------------------
-- A relative directory gets "./" in front, so cd neither searches CDPATH
-- nor reads "-" as $OLDPWD or a leading "-" as an option.
local function cd_target(dir)
    if dir:sub(1, 1) == "/" then return dir end
    return "./" .. dir
end

-- The shell line that prints the directory of the process, by MODE.
local PRINT_DIR = {
    sh  = sh_line("pwd -P", "pwd"),
    cmd = "cd",
}

-- The shell line that prints the absolute, resolved path of `dir`, taken
-- relative to `base` when given, and nothing when `dir` is not a directory
-- one can enter, by MODE. cmd.exe is best effort and untested.
local RESOLVE_DIR = {
    sh = function(base, dir)
        local steps = {}
        if base then
            steps[#steps + 1] = "cd -P " .. quote(cd_target(base))
        end
        steps[#steps + 1] = "cd -P " .. quote(cd_target(dir))
        steps[#steps + 1] = "pwd -P"
        local script = "(" .. table.concat(steps, " && ") .. ") 2>/dev/null"
        return sh_line(script, "cd pwd")
    end,
    cmd = function(base, dir)
        local steps = {}
        if base then steps[#steps + 1] = 'cd /d "' .. base .. '"' end
        steps[#steps + 1] = 'cd /d "' .. dir .. '"'
        steps[#steps + 1] = "cd"
        return "(" .. table.concat(steps, " && ") .. ") 2>NUL"
    end,
}

-- The line a shell line prints, without its line ending; nil when it
-- prints nothing or io.popen fails.
local function capture_line(cmd)
    local out = capture(cmd)
    if out == nil then return nil end
    out = out:gsub("[\r\n]+$", "")
    if out == "" then return nil end
    return out
end

-- printf is a builtin, so the input never passes through exec. Input with
-- NUL bytes, which a C string cannot carry, goes through %b as ASCII: each
-- backslash doubled, each NUL and each byte from 0x80 up written as \0ooo.
-- In multibyte locales such as SJIS and GBK, bash would otherwise read a
-- byte from 0x80 up and the backslash after it as one character.
local function printf_input(data)
    if not has_nul(data) then
        return "printf '%s' " .. quote(data)
    end
    local escaped = data:gsub("\\", "\\\\"):gsub("%z", "\\0000")
    escaped = escaped:gsub("[\128-\255]", function(c)
        return string.format("\\0%03o", c:byte())
    end)
    return "printf '%b' " .. quote(escaped)
end

-- POSIX sh. The inner subshell `( cd -P ... || exit 127; exec <argv> )`
-- runs the program found on PATH and keeps the cd to itself. The outer
-- subshell waits for it instead of exec'ing it, since a command follows,
-- and sends the shell's own diagnostics to /dev/null, such as the
-- "Killed: 9" that bash and dash print for a child killed by a signal;
-- because the redirections belong to the inner subshell, dash cannot
-- write that line into the captured stderr either. A failed cd or a
-- missing program reports to the captured stderr. The status goes to fd
-- 3, which the outer subshell opens before the program starts and the
-- program does not inherit.
local function render_sh(argv, files, cwd)
    local words = {}
    for i, a in ipairs(argv) do
        words[i] = quote(a)
    end
    if argv[1]:sub(1, 1) == "-" and argv[1]:find("/", 1, true) then
        -- exec would read "-x/prog" as an option; "./-x/prog" is the same
        words[1] = quote("./" .. argv[1])
    end
    local s = "exec " .. table.concat(words, " ")
    if cwd then
        s = "cd -P " .. quote(cd_target(cwd)) .. " || exit 127; " .. s
    end
    s = "( " .. s .. " )"
    if files.data == nil then
        s = s .. " < " .. (files.input and quote(files.input) or "/dev/null")
    end
    if files.stderr then
        s = s .. " 2> " .. quote(files.stderr)
    else
        s = s .. " 2>&1"
    end
    if files.status then
        s = (
            "( " .. s .. " 3>&-; echo \"$?\" >&3 ) 2>/dev/null 3> "
            .. quote(files.status)
        )
    else
        s = "( " .. s .. "; exit $? ) 2>/dev/null"
    end
    if files.data then
        -- A program that stops reading leaves printf a write error, not
        -- SIGPIPE, and `|| :` drops it, so under an exported pipefail the
        -- pipeline's status is still the program's.
        s = (
            "{ trap '' PIPE; " .. printf_input(files.data)
            .. " || :; } 2>/dev/null | " .. s
        )
    end
    return sh_line(s, "cd echo printf")
end

-- WINDOWS VARIANT, BEST EFFORT, UNTESTED: no Windows machine was available
-- during development. cmd.exe syntax: arguments in double quotes with an
-- embedded " doubled (cmd.exe still expands %VAR% inside them), NUL for
-- /dev/null. `call echo %^errorlevel%` expands errorlevel when the echo
-- runs, not when the line is read. The line gets one more pair of quotes
-- because `cmd /c` strips the first and the last quote of a line that
-- starts with one. There is no inline-input form (strategy basic).
local function render_cmd(argv, files, cwd)
    local function q(s)
        return '"' .. (s:gsub('"', '""')) .. '"'
    end
    if files.data then
        error("sh.popen: strategy basic needs a POSIX shell", 0)
    end
    local words = {}
    for i, a in ipairs(argv) do
        words[i] = q(a)
    end
    local s = table.concat(words, " ")
    if cwd then
        s = "cd /d " .. q(cwd) .. " && " .. s
    end
    s = s .. " < " .. (files.input and q(files.input) or "NUL")
    if files.stderr then
        s = s .. " 2> " .. q(files.stderr)
    else
        s = s .. " 2>&1"
    end
    if files.status then
        s = s .. " & call echo %^errorlevel% > " .. q(files.status)
    end
    return '"' .. s .. '"'
end

local function render(argv, files, cwd, mode)
    if (mode or MODE) == "cmd" then
        return render_cmd(argv, files or {}, cwd)
    end
    return render_sh(argv, files or {}, cwd)
end

--------------------------------------------------------------------------------
-- TEMP ROOTS AND THE PRIVATE DIRECTORY
--------------------------------------------------------------------------------
-- A directory in which this process may create files. Cached per root
-- until the next configure().
local function writable_dir(root)
    if MODE == "cmd" then
        return true   -- best effort: cmd.exe has no cheap write test
    end
    if probed[root] == nil then
        local q = quote(root)
        probed[root] = succeeded(os.execute(sh_line(
            "test -d " .. q .. " && test -w " .. q .. " && test -x " .. q,
            "test"
        )))
    end
    return probed[root]
end

local function usable(root)
    return dirs[root] ~= nil or writable_dir(root)
end

-- The root of a file strategy's private directory, or nil and why not.
-- standard takes a configured tmpdir alone; otherwise the first usable of
-- TMPDIR, TMP, TEMP and /tmp, so a stale TMPDIR does not push "auto" down
-- to basic.
local function temp_root(strategy)
    if strategy == "shmem" then
        if MODE == "sh" and usable("/dev/shm") then
            return "/dev/shm"
        end
        return nil, "/dev/shm is not a writable directory"
    end
    if config.tmpdir then
        if usable(config.tmpdir) then
            return config.tmpdir
        end
        return nil, config.tmpdir .. " is not a writable directory"
    end
    for _, var in ipairs({ "TMPDIR", "TMP", "TEMP" }) do
        local root = env(var)
        if root and usable(root) then
            return root
        end
    end
    if MODE == "sh" and usable("/tmp") then
        return "/tmp"
    end
    return nil, "no writable temp directory (TMPDIR, TMP, TEMP, /tmp)"
end

-- Relative roots are made absolute, so the paths in the shell string stay
-- valid after the `cd` of opts.cwd.
local function absolute(path)
    if MODE == "cmd" or path:sub(1, 1) == "/" then
        return path
    end
    local cwd = capture_line(PRINT_DIR[MODE])
    if not cwd then return path end
    return join(cwd, path)
end

-- The pid of the shell that echoes it: unique while it runs, which is all
-- a name prefix needs. Asked again next time when io.popen fails.
local function process_id()
    if pid == nil and MODE ~= "sh" then
        pid = false
    end
    if pid == nil then
        local out = capture(sh_line("echo $$", "echo"))
        if out then
            pid = out:match("%d+") or false
        end
    end
    return pid or false
end

-- Lua 5.1 and LuaJIT start math.random from the same seed in every
-- process, so seed it once, at the first private directory. This reseeds
-- the host's math.random too (docs/DESIGN.md section 6.3).
local function random_digits()
    if not seeded then
        seeded = true
        local digits = tostring({}):gsub("%D", "")
        local seed   = (
            os.time() + math.floor(os.clock() * 1000000)
            + (tonumber(digits:sub(-9)) or 0)
        )
        math.randomseed(math.floor(seed % 2147483647))
    end
    return string.format("%d", math.random(100000000, 999999999))
end

-- 32 hex digits that no other user can predict, from /dev/urandom; where
-- there is none (Windows), 27 decimal digits from math.random, which a
-- determined user could predict.
local function secret()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub(".", function(c)
                return string.format("%02x", c:byte())
            end))
        end
    end
    return random_digits() .. random_digits() .. random_digits()
end

local function register_sentinel()
    if sentinel then return end
    local function finalize()
        M.cleanup_all()
    end
    if newproxy then
        -- Lua 5.1 and LuaJIT run __gc for userdata only
        sentinel = newproxy(true)
        getmetatable(sentinel).__gc = finalize
    else
        sentinel = setmetatable({}, { __gc = finalize })
    end
end

local function remove_dir(path)
    if MODE == "cmd" then
        os.execute('rmdir /s /q "' .. path .. '" 2>NUL')
    else
        os.execute(sh_line("rm -rf " .. quote(path) .. " 2>/dev/null", "rm"))
    end
end

-- The directory is the one this process made: only that one holds the
-- marker, whose name nobody else knows. Opening a name that is not there
-- cannot block, unlike reading a FIFO someone put in a known place.
local function still_ours(entry)
    local f = io.open(entry.marker, "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

-- Makes a private directory under root, or returns nil and why not.
-- mkdir fails when the name exists: then another suffix is tried.
local function make_dir(root)
    local base   = absolute(root)
    local id     = process_id()
    local prefix = "luash-"
    if id then
        prefix = prefix .. id .. "-"
    end
    for _ = 1, MAX_TRIES do
        local path = join(base, prefix .. random_digits())
        local cmd
        if MODE == "cmd" then
            cmd = 'mkdir "' .. path .. '" 2>NUL'
        else
            cmd = sh_line(
                "mkdir -m 700 " .. quote(path) .. " 2>/dev/null", "mkdir"
            )
        end
        if succeeded(os.execute(cmd)) then
            local entry   = { path = path }
            entry.marker  = join(path, ".luash-" .. secret())
            local written, why = write_file(entry.marker, "")
            if not written then
                remove_dir(path)
                return nil, why
            end
            made[#made + 1] = entry
            register_sentinel()
            return entry
        end
    end
    return nil, (
        "cannot create a private directory in " .. base
        .. " (" .. MAX_TRIES .. " attempts)"
    )
end

-- The private directory under root, or nil and why not. One that lost its
-- marker is left alone (cleanup_all still tries it) and a new one is made.
local function private_dir(root)
    local entry = dirs[root]
    if entry and still_ours(entry) then
        return entry
    end
    dirs[root] = nil
    local fresh, why = make_dir(root)
    if not fresh then
        return nil, why
    end
    dirs[root] = fresh
    return fresh
end

--------------------------------------------------------------------------------
-- STRATEGIES
--------------------------------------------------------------------------------
local function strategy_available(name)
    if name == "minimal" then
        return true
    end
    if name == "basic" then
        if MODE == "cmd" then
            return false, "strategy basic needs a POSIX shell"
        end
        return true
    end
    local root, why = temp_root(name)
    if not root then
        return false, why
    end
    return true
end

local function resolve()
    if resolved then
        return resolved
    end
    local name = config.strategy
    if name ~= "auto" then
        local ok, why = strategy_available(name)
        if not ok then
            return nil, "strategy " .. name .. " unavailable: " .. why
        end
        resolved = name
        return resolved
    end
    for _, candidate in ipairs(ORDER) do
        -- a configured tmpdir says where temp files go: not /dev/shm
        local skip = (candidate == "shmem" and config.tmpdir ~= nil)
        if not skip and strategy_available(candidate) then
            resolved = candidate
            return resolved
        end
    end
    return nil, "no strategy available"
end

--------------------------------------------------------------------------------
-- RUNNING
--------------------------------------------------------------------------------
-- The longest command line exec takes here, measured once: ARG_MAX less
-- the environment (its strings, a pointer to each and room for the rest of
-- sh's arguments; ARG_SLACK when its size is unknown), and on Linux at
-- most 32 pages less one byte, the limit for a single argument
-- (MAX_ARG_STRLEN), which the command line is to `sh -c`. macOS and the
-- BSDs have no per-argument limit. The environment env lists holds the
-- variables the shell adds as well, which errs on the safe side.
local function command_limit()
    if cmd_limit == nil and MODE == "sh" then
        -- one line per value, "-" where a command fails
        local out = capture(sh_line(
            "getconf ARG_MAX 2>/dev/null || echo -;"
            .. " getconf PAGESIZE 2>/dev/null || echo -;"
            .. " uname -s 2>/dev/null || echo -;"
            .. " env | wc -c; env | wc -l",
            "getconf uname env wc echo"
        ))
        if not out then
            return false   -- io.popen failed for now: measure next time
        end
        local lines = {}
        for line in out:gmatch("[^\n]+") do
            lines[#lines + 1] = line
        end
        local arg_max   = tonumber(lines[1] or "")
        local page      = tonumber(lines[2] or "")
        local env_bytes = tonumber((lines[4] or ""):match("%d+") or "")
        local env_count = tonumber((lines[5] or ""):match("%d+") or "")
        local reserve   = ARG_SLACK
        if env_bytes and env_count and env_bytes > 0 then
            reserve = env_bytes + 8 * (env_count + 4) + 4096
        end
        local limit = false
        if arg_max and arg_max > reserve then
            limit = arg_max - reserve
        end
        if lines[3] == "Linux" and page then
            local per_arg = 32 * page - 1
            if not limit or per_arg < limit then
                limit = per_arg
            end
        end
        cmd_limit = limit
    end
    return cmd_limit or false
end

-- Runs the shell string cmd and reads its stdout to the end, passing each
-- chunk to on_stdout. Returns stdout and what h:close() reported (how,
-- code), or nil and the reason the command could not be started.
local function execute(cmd, on_stdout)
    if #cmd > ARG_SLACK then
        -- macOS and older glibc start the shell in a forked child, where
        -- an exec that fails for length goes unreported: check first.
        -- Shorter lines skip the check, which costs a shell once.
        local limit = command_limit()
        if limit and #cmd > limit then
            return nil, (
                "the command line (" .. #cmd .. " bytes) is longer than"
                .. " the system accepts (" .. limit .. " bytes)"
            )
        end
    end
    local h, err = io.popen(cmd, "r")
    if not h then
        -- the message is "<command line>: <reason>"; keep the reason
        local text = tostring(err)
        return nil, text:match(".*: (.-)$") or text
    end
    local chunks = {}
    local ok, perr = pcall(function()
        while true do
            local chunk = h:read(CHUNK)
            if not chunk then break end
            chunks[#chunks + 1] = chunk
            if on_stdout then on_stdout(chunk) end
        end
    end)
    -- close also when a callback raised, so the child is not left behind
    local _, how, code = h:close()
    if not ok then
        error(perr, 0)
    end
    return table.concat(chunks), how, code
end

-- Result for a command that could not be started.
local function failure(argv, reason, opts)
    local stderr = "sh.popen: " .. argv[1] .. ": " .. reason .. "\n"
    if opts.on_stderr then
        opts.on_stderr(stderr)
    end
    return {
        exitcode = NOT_RUN, signal = 0,
        stdout   = "",      stderr = stderr,
        cause    = "failed",
    }
end

-- Runs argv with its files in the private directory entry. Returns the
-- result and whether the directory was still this process's afterwards.
local function run_with_files(entry, argv, input, opts, files)
    if files.input then
        local written, why = write_file(files.input, input)
        if not written then
            return failure(argv, why, opts), true
        end
    end
    local cmd = render(argv, files, opts.cwd, MODE)
    local stdout, how, code = execute(cmd, opts.on_stdout)
    if not stdout then
        return failure(argv, how, opts), true
    end
    local ours   = still_ours(entry)
    local stderr = ""
    local status = nil
    if ours then
        stderr = read_file(files.stderr) or ""
        status = tonumber((read_file(files.status) or ""):match("%d+"))
    end
    if not status then
        -- the shell was killed, or the directory vanished during the run:
        -- what close() reports is the shell's status, not the program's
        status = (how == "signal") and 128 + code or NOT_RUN
        stderr = stderr .. "sh.popen: " .. argv[1] .. ": no exit status"
        if not ours then
            stderr = stderr .. " (the private directory vanished)"
        end
        stderr = stderr .. "\n"
    end
    if stderr ~= "" and opts.on_stderr then
        opts.on_stderr(stderr)
    end
    local result = {
        exitcode = exit_code(status), signal = 0,
        stdout   = stdout,            stderr = stderr,
        cause    = "exited",
    }
    return result, ours
end

-- shmem and standard: stdin, stderr and exit status through files in the
-- private directory under root.
local function run_files(root, argv, input, opts)
    local entry, why = private_dir(root)
    if not entry then
        return failure(argv, why, opts)
    end
    counter = counter + 1
    local n     = tostring(counter)
    local files = {
        stderr = join(entry.path, "err-" .. n),
        status = join(entry.path, "st-" .. n),
    }
    if input ~= "" then
        files.input = join(entry.path, "in-" .. n)
    end
    local ok, result, ours = pcall(
        run_with_files, entry, argv, input, opts, files
    )
    if not ok then
        ours = still_ours(entry)
    end
    if ours then
        -- never remove names in a directory someone else made
        for _, path in pairs(files) do
            os.remove(path)
        end
    end
    if not ok then
        error(result, 0)
    end
    return result
end

-- basic and minimal: stderr merged into stdout, status from h:close().
local function run_merged(argv, input, opts)
    local files = {}
    if input ~= "" then
        files.data = input
    end
    local cmd = render(argv, files, opts.cwd, MODE)
    local stdout, how, code = execute(cmd, opts.on_stdout)
    if not stdout then
        return failure(argv, how, opts)
    end
    local exitcode = 0
    if close_reports_status() then
        exitcode = exit_code(close_code(how, code) or 0)
    end
    return {
        exitcode = exitcode, signal = 0,
        stdout   = stdout,   stderr = "",
        cause    = "exited",
    }
end

--------------------------------------------------------------------------------
-- PUBLIC FUNCTIONS
--------------------------------------------------------------------------------
---Reports whether io.popen works and the configured strategy can run.
---@return boolean available
---@return string|nil reason  why not, when available is false
function M.available()
    local works, why = popen_works()
    if not works then
        return false, why
    end
    local name, reason = resolve()
    if not name then
        return false, reason
    end
    return true
end

---Describes the resolved strategy (docs/DESIGN.md section 5).
---@return table capabilities  name, strategy, stdin, separate_stderr,
---                            streaming, exitcode, signals
function M.capabilities()
    local name = resolve() or config.strategy
    local s    = STRATEGIES[name] or STRATEGIES.minimal
    return {
        name            = "popen",
        strategy        = name,
        stdin           = s.stdin,
        separate_stderr = s.files,
        streaming       = true,
        exitcode        = s.files or close_reports_status(),
        signals         = false,
    }
end

---Sets the strategy and temp root; fields left out take their defaults.
---@param opts table|nil  strategy: "auto" (default), "shmem", "standard",
---                       "basic" or "minimal"; tmpdir: root for the private
---                       directory of "standard", and "auto" then skips
---                       "shmem", which always uses /dev/shm; default: the
---                       first writable of TMPDIR, TMP, TEMP and /tmp
function M.configure(opts)
    opts = opts or {}
    local strategy = opts.strategy or "auto"
    if strategy ~= "auto" and not STRATEGIES[strategy] then
        error("sh.popen: unknown strategy " .. tostring(strategy), 2)
    end
    local tmpdir = opts.tmpdir
    if tmpdir ~= nil and (type(tmpdir) ~= "string" or tmpdir == "") then
        error("sh.popen: tmpdir must be a non-empty string", 2)
    end
    config.strategy = strategy
    config.tmpdir   = tmpdir
    resolved        = nil
    probed          = {}
end

---Changes the directory that run() enters when opts.cwd is nil (emulated
---`cd`: io.popen has no chdir). `dir` is taken relative to that directory.
---@param dir string
---@return true|nil ok
---@return string|nil err  when `dir` is not a directory one can enter
function M.chdir(dir)
    if type(dir) ~= "string" or dir == "" or has_nul(dir) then
        return nil, "sh.popen.chdir: expected a directory name"
    end
    local path = capture_line(RESOLVE_DIR[MODE](emulated, dir))
    if not path then
        return nil, dir .. ": cannot change directory"
    end
    emulated = path
    return true
end

---The directory run() enters: the one chdir() moved to, else that of the
---process.
---@return string|nil path
---@return string|nil err
function M.getcwd()
    if emulated then return emulated end
    local path = capture_line(PRINT_DIR[MODE])
    if not path then
        return nil, "sh.popen.getcwd: cannot read the working directory"
    end
    return path
end

---Lists the strategies that can run here, most capable first.
---@return string[] names
function M.available_strategies()
    local names = {}
    if not popen_works() then
        return names
    end
    for _, name in ipairs(ORDER) do
        if strategy_available(name) then
            names[#names + 1] = name
        end
    end
    return names
end

---Removes the private directories and every file in them. The next run
---of a file strategy makes a new directory. A run in progress at that
---moment loses its stderr and exit status: it reports exit code 127 and
---"the private directory vanished".
function M.cleanup_all()
    for _, entry in ipairs(made) do
        -- only a directory that still holds this process's marker
        if still_ours(entry) then
            remove_dir(entry.path)
        end
    end
    made = {}
    dirs = {}
end

---Runs argv[1], found on PATH, with the remaining elements as arguments.
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  stdin for the child; "" or nil for none
---@param opts table|nil  on_stdout(chunk), on_stderr(chunk), cwd (default:
---                       the directory chdir() moved to)
---@return table result  exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    input = input or ""
    opts  = opts or {}
    if type(input) ~= "string" then
        error("sh.popen: input must be a string", 2)
    end
    local cwd = opts.cwd
    if cwd ~= nil and (type(cwd) ~= "string" or has_nul(cwd)) then
        error("sh.popen: cwd must be a string without NUL bytes", 2)
    end
    local name, why = resolve()
    if not name then
        return failure(argv, why, opts)
    end
    if not STRATEGIES[name].stdin and input ~= "" then
        error(
            "sh.popen: strategy " .. name .. " cannot pass input to "
            .. argv[1], 2
        )
    end
    if cwd == "" then
        -- chdir("") fails, but `cd ''` stays put in some shells
        return failure(argv, "cannot change to an empty directory name", opts)
    end
    if cwd == nil then cwd = emulated end
    opts = {
        on_stdout = opts.on_stdout, on_stderr = opts.on_stderr, cwd = cwd,
    }
    if argv[1]:sub(1, 1) == "-" and not argv[1]:find("/", 1, true) then
        -- exec would read it as an option, and has no portable "--"
        return failure(
            argv, "a program name starting with - cannot be run by sh", opts
        )
    end
    if not STRATEGIES[name].files then
        return run_merged(argv, input, opts)
    end
    local root, reason = temp_root(name)
    if not root then
        return failure(argv, reason, opts)
    end
    return run_files(root, argv, input, opts)
end

---Builds the shell string for one run; exposed for the tests.
---@param argv string[]
---@param files table|nil  input, stderr, status: absolute paths of the temp
---                        files; data: input given on the command line
---                        (basic); nil or {} for minimal
---@param cwd string|nil  directory to cd into first
---@param mode string|nil  "sh" (POSIX) or "cmd" (Windows); default: this
---                        platform
---@return string command
function M._render(argv, files, cwd, mode)
    return render(argv, files, cwd, mode)
end

return M
