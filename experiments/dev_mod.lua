local M = {}

local sh = require('sh')

local function pwd_fn()
    return pwd()
end

M.pwd = pwd_fn
return M
