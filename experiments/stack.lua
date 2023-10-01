require("sh").install()

-- print('User:', whoami())
-- print('Current directory:', cd("..") : pwd())

-- print(cat("sh.lua"))
print(cat("sh.lua") : wc("-l"))


-- Stack Table
-- Uses a table as stack, use <table>:push(value) and <table>:pop()
-- Lua 5.1 compatible

-- GLOBAL
Stack = {}

-- Create a Table with stack functions
function Stack:Create()

    -- stack table
    local t = {}
    -- entry table
    t._et = {}

    -- push a value on to the stack
    function t:push(...)
        if ... then
            local targs = {...}
            -- add values
            for _,v in ipairs(targs) do
                table.insert(self._et, v)
            end
        end
    end

    -- pop a value from the stack
    function t:pop(num)

        -- get num values from stack
        local num = num or 1

        -- return table
        local entries = {}

        -- get values into entries
        for i = 1, num do
            -- get last entry
            if #self._et ~= 0 then
                table.insert(entries, self._et[#self._et])
                -- remove last value
                table.remove(self._et)
            else
                break
            end
        end
        -- return unpacked entries
        return table.unpack(entries)
    end

    -- get entries
    function t:getn()
        return #self._et
    end

    -- list values
    function t:list()
        for i,v in pairs(self._et) do
            print(i, v)
        end
    end
    return t
end


local s = Stack:Create()
s:push("a")
s:push("b", "c")
print(s:pop(1))
print(s:pop(2))
