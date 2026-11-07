---
--- A simple LIFO stack.
---
local Stack = {}
Stack.__index = Stack

function Stack:new()
    return setmetatable({ _entries = {} }, Stack)
end

function Stack:push(value)
    table.insert(self._entries, value)
end

--- Pop and return the top value, or nil if empty.
function Stack:pop()
    if #self._entries == 0 then
        return nil
    end
    local value = self._entries[#self._entries]
    table.remove(self._entries)
    return value
end

function Stack:size()
    return #self._entries
end

return Stack
