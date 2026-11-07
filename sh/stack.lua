---
--- sh.stack: a LIFO stack, used by the pushd and popd builtins.
---

local M = {}
M.__index = M

--- Create an empty stack; call as `Stack:new()`.
---@return table stack
function M:new()
    return setmetatable({ _entries = {} }, M)
end

--- Push `value` on top of the stack.
---@param value any
function M:push(value)
    self._entries[#self._entries + 1] = value
end

--- Remove and return the top value, or nil when the stack is empty.
---@return any value
function M:pop()
    local n = #self._entries
    if n == 0 then return nil end
    local value = self._entries[n]
    self._entries[n] = nil
    return value
end

--- The number of values on the stack.
---@return integer
function M:size()
    return #self._entries
end

return M
