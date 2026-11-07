---
--- Backend dispatcher for sh's process I/O layer.
---
--- This module presents a single pipe_simple() entry point and delegates to
--- whichever backend the caller has selected (or the best one detected at
--- first use).
---
--- Backend selection priority (auto-detect):
---   1. posix   – full-featured, no temp files  (requires luaposix)
---   2. luv     – full-featured, no temp files  (requires luv / libuv)
---   3. popen   – pure Lua, strategy-dependent  (always available)
---
--- Manual selection:
---
---   local pipe = require("sh.pipe")
---   pipe.set_backend("luv")
---   pipe.set_backend("popen", { strategy = "shmem" })
---
--- Querying:
---
---   pipe.backend_name()          --> e.g. "posix"
---   pipe.available_backends()    --> e.g. {"posix", "luv", "popen"}
---

local M = {}

---------------------------------------------------------------------------
-- Backend registry
---------------------------------------------------------------------------

--- Each entry: { module_name, loader_fn }
--- The loader returns the backend module or nil on failure.
local backend_specs = {
    { name = "posix", load = function()
        local ok, mod = pcall(require, "sh.pipe_posix")
        return ok and mod or nil
    end },
    { name = "luv", load = function()
        local ok, mod = pcall(require, "sh.pipe_luv")
        -- Also verify that luv itself loaded (it's a transitive require).
        if ok and mod then
            local uv_ok = pcall(require, "luv")
            return uv_ok and mod or nil
        end
        return nil
    end },
    { name = "popen", load = function()
        local ok, mod = pcall(require, "sh.pipe_popen")
        return ok and mod or nil
    end },
}

--- Cache of successfully loaded backend modules, keyed by name.
local loaded = {}

local function load_backend(name)
    if loaded[name] then return loaded[name] end
    for _, spec in ipairs(backend_specs) do
        if spec.name == name then
            local mod = spec.load()
            if mod then loaded[name] = mod end
            return mod
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Active backend
---------------------------------------------------------------------------

local active_backend  -- resolved lazily

--- Auto-detect: try each backend in priority order, return the first that
--- loads successfully.
local function detect()
    for _, spec in ipairs(backend_specs) do
        local mod = load_backend(spec.name)
        if mod then return mod end
    end
    error("sh.pipe: no usable backend found (tried posix, luv, popen)")
end

local function get_backend()
    if not active_backend then
        active_backend = detect()
    end
    return active_backend
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Manually select a backend by name.
--- `opts` is forwarded to the backend module (e.g. { strategy = "shmem" }
--- for the popen backend).
function M.set_backend(name, opts)
    local mod = load_backend(name)
    if not mod then
        error("sh.pipe: backend '" .. name .. "' is not available")
    end
    -- Apply options.
    if opts then
        for k, v in pairs(opts) do
            mod[k] = v
        end
    end
    active_backend = mod
end

--- Return the name of the active backend (triggers auto-detect if needed).
function M.backend_name()
    return get_backend().name
end

--- Return a list of backend names that can be loaded on this system.
function M.available_backends()
    local result = {}
    for _, spec in ipairs(backend_specs) do
        if load_backend(spec.name) then
            result[#result + 1] = spec.name
        end
    end
    return result
end

--- The main entry point.  Signature is identical across all backends:
---   pipe_simple(input, cmd, args, verbose)
---     → exit_status, wait_cause, stdout_string, stderr_string
function M.pipe_simple(input, cmd, args, verbose)
    return get_backend().pipe_simple(input, cmd, args, verbose)
end

return M
