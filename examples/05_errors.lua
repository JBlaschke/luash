-- A failing command raises by default. Catch it, or turn raising off.
local sh = require("sh")

-- When the program wrote to stderr, that text is the error message.
local ok, err = pcall(sh.ls, "/no/such/directory")
print(ok, err)

-- Otherwise the message names the pipeline and how it ended.
ok, err = pcall(function() return sh.sh("-c", "exit 3") end)
print(ok, err)                 -- false  sh -c 'exit 3': exit status 3

-- With raise_errors off, the Result comes back and you check it.
sh.config.raise_errors = false
local r = sh.grep("needle", { __input = "hay\n" })
if r.__exitcode ~= 0 then
    print("grep found nothing: status " .. r.__exitcode)
end

-- A program that cannot be started is reported the way a shell reports
-- it: exit status 127 and a message naming the program (its wording
-- depends on the backend).
r = sh.no_such_program_xyz()
print(r.__exitcode)            -- 127
print(sh.stderr(r))
sh.config.raise_errors = true

-- The builtins never raise; they report through the Result.
local c = sh.cd("/no/such/directory")
print(c.__exitcode, sh.stderr(c))
