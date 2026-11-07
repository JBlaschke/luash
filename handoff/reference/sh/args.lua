---
--- Argument normalization: converts the mixed positional / named-key tables
--- that callers pass into flat argument lists plus piped-through state.
---
--- NOTE on flag ordering: Lua tables do not preserve insertion order for
--- non-integer keys.  If you need flags in a specific order, pass them as
--- positional strings instead:
---
---     sh.curl(url, "-H", "Content-Type: application/json", "-d", "body")
---
--- The {key=value} shorthand (e.g. {H="...", d="..."}) is convenient but
--- the resulting flag order is undefined.
---

local _tostring = tostring

local M = {}

--- Format a single flag and its value into a CLI string.
--- Examples: format_flag("-v", true) => "-v"
---           format_flag("--output", "file.txt") => "--output=file.txt"
local function format_flag(key, value)
    if not value then return key end
    if type(value) == "boolean" and value then return key end
    if type(value) == "string" and #value > 0 then return key .. "=" .. value end
    if type(value) == "number" then return key .. "=" .. _tostring(value) end
    error("invalid argument type " .. type(value) .. " for flag " .. key)
end

--- Recursively walk a (possibly nested) argument table and produce a flat
--- result containing:
---   .args      – array of string arguments
---   .input     – concatenated stdin data (from piped __input fields)
---   .stdout    – pass-through stdout from a previous pipeline stage
---   .stderr    – pass-through stderr
---   .exitcode  – pass-through exit code
---   .signal    – pass-through signal
function M.flatten(t)
    local result = {
        args     = {},
        input    = "",
        stdout   = "",
        stderr   = "",
        exitcode = nil,
        signal   = nil,
    }

    local function walk(tbl)
        -- First pass: collect sequential (integer-keyed) entries so we can
        -- skip them during the pairs() pass below.
        local seq = {}
        for i = 1, #tbl do
            seq[i] = true
            local v = tbl[i]
            if type(v) == "table" then
                walk(v)
            else
                table.insert(result.args, _tostring(v))
            end
        end

        -- Second pass: named keys.
        for k, v in pairs(tbl) do
            if seq[k] then
                -- already handled above
            elseif k == "__input"    then result.input    = result.input .. v
            elseif k == "__stdout"   then result.stdout   = result.stdout .. v
            elseif k == "__stderr"   then result.stderr   = result.stderr .. v
            elseif k == "__exitcode" then result.exitcode  = v
            elseif k == "__signal"   then result.signal    = v
            elseif type(k) == "string" and k:sub(1, 1) ~= "_" then
                local flag = (#k > 1) and ("--" .. k) or ("-" .. k)
                table.insert(result.args, format_flag(flag, v))
            end
        end
    end

    walk(t)
    return result
end

--- Trim leading and trailing whitespace.
function M.strip(str)
    return str:match("^%s*(.-)%s*$")
end

return M
