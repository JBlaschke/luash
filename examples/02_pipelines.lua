-- Chain commands: the stdout of one becomes the stdin of the next.
local sh = require("sh")

-- A Result passed as an argument feeds the command's stdin.
print(sh.sort(sh.printf("b\na\nc\n"), "-r"))   -- c, b, a

-- Chained calls read like a shell pipeline. Each call after the first is
-- looked up in the sh module, so only the first one needs the prefix.
print(sh.seq(1, 10):grep("5"):wc("-l"))        -- 1

-- Lua lets you drop the parentheses around a single string argument.
sh.seq(1, 5) : tail("-n", 2) : print()         -- 4, 5
sh.ls "/" : head "-3" : print()                -- the first three entries

-- Several Results feed one command: their outputs are concatenated, and
-- the pipeline renders them as a group.
local both = sh.wc(sh.seq(1, 10), sh.seq(20, 25), "-l")
print(both)                                    -- 16
print(both.__pipeline)                         -- { seq 1 10; seq 20 25; } | wc -l

-- Literal input: a table with an __input field is stdin.
print(sh.tr({ __input = "hello" }, "a-z", "A-Z"))   -- HELLO

-- The stages run one after another: a stage runs to completion, and its
-- whole output is then the input of the next stage.
