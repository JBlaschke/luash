---
--- sh.pipe: runs a command through the backend in use (DESIGN.md section
--- 6.4), with the verbose and trace plumbing of sh.config.
---
--- It reads the configuration table that sh/init.lua hands over with
--- set_config(): verbose, trace and sink, at each run. The backend comes
--- from sh.backend, which selected it when sh loaded or at
--- sh.set_backend(). This module never requires sh.init. run() is called
--- directly, not through sys.load_pcall: it calls config.sink, which may
--- use the commands that sh.install() provides.
---

local backend = require("sh.backend")

local M = {}

-- The configuration in use until init.lua calls set_config.
local config = {
    verbose      = false,
    trace        = false,
    raise_errors = true,
}

-- The on_stdout or on_stderr callback for verbose mode.
local function writer(stream, handle)
    local sink = config.sink
    if sink then
        return function(chunk) sink(stream, chunk) end
    end
    return function(chunk)
        handle:write(chunk)
        handle:flush()
    end
end

local function trace(argv, pipeline)
    local text = pipeline and tostring(pipeline) or table.concat(argv, " ")
    local line = "+ " .. text .. "\n"
    if config.sink then
        config.sink("trace", line)
        return
    end
    io.stderr:write(line)
    io.stderr:flush()
end

--- Use `tbl` as the configuration (sh.config); init.lua calls this.
---@param tbl table
function M.set_config(tbl)
    if type(tbl) ~= "table" then
        error("sh.pipe.set_config: expected a table, got a " .. type(tbl), 2)
    end
    config = tbl
end

--- Run `argv` with `input` on stdin through the backend in use and return
--- the backend's result table. Streams output when config.verbose is set
--- and writes the trace line when config.trace is set.
---@param argv string[] the program and its arguments
---@param input string|nil stdin data
---@param pipeline table|nil what the trace line shows (tostring)
---@return table result { exitcode, signal, stdout, stderr, cause }
function M.run(argv, input, pipeline)
    input = input or ""
    local mod  = backend.current()
    local caps = mod.capabilities()
    if caps.stdin == false and input ~= "" then
        local label = mod.name
        if caps.strategy then label = label .. "/" .. caps.strategy end
        local msg = "sh: backend " .. label .. " cannot pass input to "
        error(msg .. tostring(argv[1]), 0)
    end
    local opts = {}
    if config.verbose then
        opts.on_stdout = writer("stdout", io.stdout)
        opts.on_stderr = writer("stderr", io.stderr)
    end
    if config.trace then trace(argv, pipeline) end
    local result = mod.run(argv, input, opts)
    if type(result) ~= "table" then
        local msg = "sh.pipe: backend " .. mod.name .. " returned no result"
        error(msg, 0)
    end
    return result
end

return M
