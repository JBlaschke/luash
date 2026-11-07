-- luaposix process backend for LuaSH (handoff/DESIGN.md sections 4, 6.1).
--
-- run() forks, connects three pipes to the child's stdin, stdout and
-- stderr, and execs the program found on PATH. The parent then runs one
-- poll loop that writes the input in slices as the child reads it and
-- collects both outputs as they arrive, so input and output of any size
-- flow without deadlock. SIGPIPE is ignored in the parent while the loop
-- runs: a child that exits before reading all of its input turns the
-- next write into EPIPE instead of killing the host.
--
-- A fourth pipe, closed on exec, tells a program that could not be
-- started (cause "failed") apart from one that exits with status 127.
--
-- luaposix is loaded with pcall: without it this module still loads and
-- available() returns false with the reason.
local M = { name = "posix" }

local ok, posix = pcall(require, "posix")

local READ_SIZE  = 4096    -- bytes per read from stdout or stderr
local WRITE_SIZE = 65536   -- at most this many input bytes per write

-- Every luaposix field this module uses.
local REQUIRED = {
    "_exit", "chdir", "close", "dup2", "errno", "execp", "fcntl", "fork",
    "pipe", "poll", "read", "signal", "wait", "write",
    "EAGAIN", "EINTR", "EPIPE", "FD_CLOEXEC", "F_SETFD", "F_SETFL",
    "O_NONBLOCK", "SIGPIPE", "SIG_IGN",
}

-- require's error message on one line, without the paths it searched.
local function one_line(msg)
    msg = msg:gsub("\n\tno [^\n]*", "")
    msg = msg:gsub("%s*\n%s*", " ")
    return (msg:gsub(":%s*$", ""))
end

-- Why this backend cannot run here, or nil when it can.
local unavailable = nil
if not ok then
    unavailable = one_line(tostring(posix))
else
    for _, key in ipairs(REQUIRED) do
        if posix[key] == nil then
            unavailable = "luaposix has no posix." .. key
            break
        end
    end
end

-- The host's SIGPIPE disposition while a run has replaced it with SIG_IGN,
-- nil otherwise. A child started by a nested run (one started from an
-- output callback) gets it back before exec, since exec keeps SIG_IGN.
local host_sigpipe = nil

local function check_argv(argv)
    if type(argv) ~= "table" or argv[1] == nil then
        error("sh.backend.posix.run: argv must be a non-empty array", 3)
    end
    for i = 1, #argv do
        if type(argv[i]) ~= "string" then
            error(
                "sh.backend.posix.run: argv[" .. i .. "] is not a string", 3
            )
        end
    end
end

-- Closes every descriptor in t, a table of descriptors by name.
local function close_all(t)
    for key, fd in pairs(t) do
        posix.close(fd)
        t[key] = nil
    end
end

-- Opens the stdin, stdout, stderr and status pipes. Returns their eight
-- descriptors by name (in_r, in_w, out_r, ...), or nil and the error
-- after closing those already open.
local function open_pipes()
    local fds = {}
    for _, name in ipairs({ "in", "out", "err", "st" }) do
        local r, w = posix.pipe()
        if r == nil then
            close_all(fds)
            return nil, w
        end
        fds[name .. "_r"] = r
        fds[name .. "_w"] = w
    end
    return fds
end

-- Runs in the forked child: moves the pipe ends onto descriptors 0, 1 and
-- 2, changes directory and execs the program. Returns only on failure,
-- with the reason.
local function exec_child(fds, program, args, cwd)
    posix.close(fds.in_w)
    posix.close(fds.out_r)
    posix.close(fds.err_r)
    posix.close(fds.st_r)
    posix.dup2(fds.in_r, 0)
    posix.dup2(fds.out_w, 1)
    posix.dup2(fds.err_w, 2)
    -- Close the spare originals. An end that landed on 0, 1 or 2 (the
    -- host had closed that descriptor) is already in use as one of them.
    for _, fd in ipairs({ fds.in_r, fds.out_w, fds.err_w }) do
        if fd > 2 then posix.close(fd) end
    end
    if host_sigpipe ~= nil then
        posix.signal(posix.SIGPIPE, host_sigpipe)
    end
    if cwd ~= nil then
        local done, err = posix.chdir(cwd)
        if done == nil then return err end
    end
    local _, _, errno = posix.execp(program, args)
    return (posix.errno(errno))
end

-- Starts argv[1] in a child process. Returns a job table with the pid and
-- the parent's ends of the pipes, or nil and the reason it failed.
local function spawn(argv, cwd)
    local args = {}
    for i = 2, #argv do
        args[i - 1] = argv[i]
    end
    local fds, err = open_pipes()
    if fds == nil then return nil, "pipe: " .. tostring(err) end
    -- Close on exec keeps the parent's ends out of children that a nested
    -- run starts, and closes the status pipe once exec has succeeded.
    for _, key in ipairs({ "in_w", "out_r", "err_r", "st_r", "st_w" }) do
        posix.fcntl(fds[key], posix.F_SETFD, posix.FD_CLOEXEC)
    end

    local pid, ferr = posix.fork()
    if pid == nil then
        close_all(fds)
        return nil, "fork: " .. tostring(ferr)
    end
    if pid == 0 then
        -- Never raise here: a Lua error would unwind through the child's
        -- copy of the host program. _exit skips the host's stdio buffers.
        local _, reason = pcall(exec_child, fds, argv[1], args, cwd)
        local text = "sh: " .. argv[1] .. ": " .. tostring(reason) .. "\n"
        pcall(posix.write, 2, text)
        pcall(posix.write, fds.st_w, "x")
        posix._exit(127)
    end

    posix.close(fds.in_r)
    posix.close(fds.out_w)
    posix.close(fds.err_w)
    posix.close(fds.st_w)
    return {
        name  = argv[1],  pid    = pid,       status = fds.st_r,
        stdin = fds.in_w, stdout = fds.out_r, stderr = fds.err_r,
        out   = {},       err    = {},   -- chunks of stdout and stderr
    }
end

-- True when poll reported anything for this entry: data, space, hang-up,
-- error or a closed descriptor. read or write then tells which.
local function woke(entry)
    local ev = entry.revents
    return ev ~= nil and (ev.IN or ev.OUT or ev.HUP or ev.ERR or ev.NVAL)
end

-- Writes input to the child and reads its stdout and stderr in one poll
-- loop until all three pipes are closed: input fully written or refused,
-- both outputs at EOF. Chunks go to job.out and job.err and to the
-- callbacks in opts.
local function pump(job, input, opts)
    local pollfds = {}
    local pos     = 1   -- next byte of input to write

    local function finish(key)
        pollfds[job[key]] = nil
        posix.close(job[key])
        job[key] = nil
    end

    local function feed()
        local slice = input:sub(pos, pos + WRITE_SIZE - 1)
        local n, _, errno = posix.write(job.stdin, slice)
        if n ~= nil then
            pos = pos + n
            if pos > #input then finish("stdin") end
        elseif errno ~= posix.EAGAIN and errno ~= posix.EINTR then
            finish("stdin")   -- EPIPE: the child no longer reads stdin
        end
    end

    local function drain(key, chunks, callback)
        local chunk, _, errno = posix.read(job[key], READ_SIZE)
        local again = errno == posix.EINTR or errno == posix.EAGAIN
        if chunk == nil and again then return end
        if chunk == nil or chunk == "" then
            finish(key)
        else
            chunks[#chunks + 1] = chunk
            if callback then callback(chunk) end
        end
    end

    if input == "" then
        finish("stdin")
    else
        posix.fcntl(job.stdin, posix.F_SETFL, posix.O_NONBLOCK)
        pollfds[job.stdin] = { events = { OUT = true } }
    end
    pollfds[job.stdout] = { events = { IN = true } }
    pollfds[job.stderr] = { events = { IN = true } }

    while next(pollfds) ~= nil do
        local ready, msg, errno = posix.poll(pollfds, -1)
        if ready == nil and errno ~= posix.EINTR then
            -- Give up; run() closes the pipes, which ends the child's I/O.
            local text = "sh: " .. job.name .. ": poll: " .. tostring(msg)
            job.err[#job.err + 1] = text .. "\n"
            if opts.on_stderr then opts.on_stderr(text .. "\n") end
            return
        end
        if ready ~= nil then
            if job.stdin and woke(pollfds[job.stdin]) then feed() end
            if job.stdout and woke(pollfds[job.stdout]) then
                drain("stdout", job.out, opts.on_stdout)
            end
            if job.stderr and woke(pollfds[job.stderr]) then
                drain("stderr", job.err, opts.on_stderr)
            end
        end
    end
end

-- Waits for the child. Returns exitcode, signal and cause.
local function reap(job)
    local pid, how, code
    repeat
        pid, how, code = posix.wait(job.pid)
    until pid ~= nil or code ~= posix.EINTR
    -- The status pipe holds a byte when exec failed and is at EOF when
    -- exec closed it. The child has ended, so this read does not block.
    local mark, errno
    repeat
        mark, _, errno = posix.read(job.status, 1)
    until mark ~= nil or errno ~= posix.EINTR
    posix.close(job.status)
    local failed = mark ~= nil and mark ~= ""
    local cause  = failed and "failed" or "exited"

    -- No status (the host ignores SIGCHLD, say): success as far as known.
    if pid == nil then return failed and 127 or 0, 0, cause end
    if how == "exited" then return code, 0, cause end
    return 127, code, "killed"   -- "killed" or "stopped"
end

-- The result for a program whose process could not be created.
local function failure(name, reason, opts)
    local text = "sh: " .. name .. ": " .. reason .. "\n"
    if opts.on_stderr then opts.on_stderr(text) end
    return {
        exitcode = 127, signal = 0,    cause = "failed",
        stdout   = "",  stderr = text,
    }
end

---Reports whether luaposix is loaded and has every function this uses.
---@return boolean available
---@return string|nil reason  why not, when available is false
function M.available()
    if unavailable then return false, unavailable end
    return true
end

---Describes this backend (handoff/DESIGN.md section 5).
---@return table capabilities  a new table on each call
function M.capabilities()
    return {
        name            = "posix",
        strategy        = nil,
        stdin           = true,
        separate_stderr = true,
        streaming       = true,
        exitcode        = true,
        signals         = true,
    }
end

---Accepts and ignores options; this backend has none.
---@param _ table|nil
function M.configure(_)
end

---Runs argv[1], found on PATH, with argv[2], ... as its arguments. A
---program that cannot be started gives exitcode 127, cause "failed" and
---the reason in stderr; only an invalid argv raises.
---@param argv string[]  program and arguments, passed verbatim
---@param input string|nil  written to the child's stdin, which then closes
---@param opts table|nil  on_stdout(chunk), on_stderr(chunk), cwd
---@return table result  exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    if unavailable then
        error("sh.backend.posix.run: " .. unavailable, 2)
    end
    input = input == nil and "" or tostring(input)
    opts  = opts or {}

    local job, reason = spawn(argv, opts.cwd)
    if job == nil then return failure(argv[1], reason, opts) end

    local previous = posix.signal(posix.SIGPIPE, posix.SIG_IGN)
    local outer    = host_sigpipe
    if outer == nil then host_sigpipe = previous end
    -- An error from a callback still closes the pipes, reaps the child and
    -- restores SIGPIPE before it propagates.
    local pumped, err = pcall(pump, job, input, opts)
    for _, key in ipairs({ "stdin", "stdout", "stderr" }) do
        if job[key] then posix.close(job[key]) end
    end
    local exitcode, signal, cause = reap(job)
    if previous ~= nil then posix.signal(posix.SIGPIPE, previous) end
    host_sigpipe = outer
    if not pumped then error(err, 0) end

    return {
        exitcode = exitcode,              signal = signal, cause = cause,
        stdout   = table.concat(job.out), stderr = table.concat(job.err),
    }
end

return M
