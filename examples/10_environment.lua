-- pushenv and popenv are builtins: they change the environment that the
-- commands run in, and put it back as it was.
local sh = require("sh")

-- What a program sees of two variables.
local seen = sh.command("sh", "-c", 'echo "${COLOUR-unset} ${SIZE-unset}"')

print(seen())                          -- unset unset
sh.pushenv({ COLOUR = "red", SIZE = 3 })
print(seen())                          -- red 3

-- The calls nest. A string is NAME=value, and false removes a variable.
sh.pushenv("COLOUR=blue", { SIZE = false })
print(seen())                          -- blue unset
sh.popenv()
print(seen())                          -- red 3
sh.popenv()
print(seen())                          -- unset unset

-- pushenv and popenv chain like commands, around the commands they are for.
sh.pushenv({ TZ = "UTC" }) : date("+%Z") : popenv() : print()

-- A variable that cannot be changed is reported, never raised, and so is
-- a popenv with nothing left to put back.
local r = sh.popenv()
print(r.__exitcode, sh.stderr(r))
