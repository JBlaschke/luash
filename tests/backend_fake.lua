-- The smallest implementation of the backend contract in handoff/DESIGN.md
-- section 4: io.popen with stdin from a temporary file and stderr merged
-- into stdout. It exists so that sh/init.lua and tests/test_backend.lua
-- can be developed and run before the real backends exist, and as a worked
-- example of the contract.
local M = { name = "fake" }

-- Does h:close() report the exit status? Lua 5.2 and newer do; Lua 5.1 and
-- LuaJIT without 5.2 compatibility return only true.
local reports_status = false
do
    local h = io.popen("exit 7", "r")
    if h then
        local _, _, code = h:close()
        reports_status = (code == 7)
    end
end

local function quote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local function check_argv(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("backend_fake.run: argv must be a non-empty array", 3)
    end
    for i, a in ipairs(argv) do
        if type(a) ~= "string" then
            error("backend_fake.run: argv[" .. i .. "] is not a string", 3)
        end
    end
end

local function write_input(input)
    local path = os.tmpname()
    local f    = assert(io.open(path, "wb"))
    f:write(input)
    f:close()
    return path
end

---Reports whether io.popen works on this interpreter.
---@return boolean available
---@return string|nil reason
function M.available()
    local ok, h = pcall(io.popen, "exit 0", "r")
    if not ok or not h then
        return false, "io.popen is not supported by this interpreter"
    end
    h:close()
    return true
end

---@return table capabilities  see handoff/DESIGN.md section 5
function M.capabilities()
    return {
        name            = "fake",
        strategy        = nil,
        stdin           = true,
        separate_stderr = false,
        streaming       = false,
        exitcode        = reports_status,
        signals         = false,
    }
end

function M.configure(_)
end

---Runs argv[1] with the remaining elements as its arguments.
---@param argv string[]
---@param input string|nil
---@param opts table|nil  fields on_stdout, on_stderr, cwd
---@return table result  fields exitcode, signal, stdout, stderr, cause
function M.run(argv, input, opts)
    check_argv(argv)
    input = input or ""
    opts  = opts or {}
    local words = {}
    for i, a in ipairs(argv) do
        words[i] = quote(a)
    end
    local path = write_input(input)
    local cmd  = table.concat(words, " ") .. " < " .. quote(path)
    if opts.cwd then
        cmd = "cd " .. quote(opts.cwd) .. " && " .. cmd
    end
    -- The command's stderr is merged into stdout. The subshell around it
    -- discards the shell's own diagnostics, such as the "Killed: 9" that
    -- bash prints for a child that died by signal; the trailing `exit`
    -- stops the shell from exec'ing the command in the subshell's place,
    -- which would make the outer shell print that line on the host's
    -- stderr.
    cmd = "( " .. cmd .. " 2>&1; exit $? ) 2>/dev/null"
    local h   = assert(io.popen(cmd, "r"))
    local out = h:read("*a") or ""
    local _, how, code = h:close()
    os.remove(path)

    local exitcode = 0
    if reports_status then
        if how == "signal" then
            exitcode = 128 + code
        else
            exitcode = code
        end
    end
    if opts.on_stdout and out ~= "" then
        opts.on_stdout(out)
    end
    return {
        exitcode = exitcode, signal = 0,
        stdout   = out,      stderr = "",
        cause    = "exited",
    }
end

return M
