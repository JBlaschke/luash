-- Build commands and pipelines first, look at them, run them later.
local sh = require("sh")

local c = sh.Command("ls", "-l")      -- nothing runs yet
c:arg("/tmp"):flag("a")
print(c)                              -- ls -l /tmp -a
print(c:argv()[1], #c:argv())         -- ls  4

-- A Pipeline comes from Command:pipe() or sh.Pipeline(); on Lua 5.3 and
-- newer, `a | b` builds one too.
local p = sh.Command("seq", 1, 10):pipe(sh.Command("wc", "-l"))
print(p)                              -- seq 1 10 | wc -l
print(p:run())                        -- 10

-- Literal input belongs to a Command and is never rendered.
local first = sh.Command("sort"):input("c\nb\na\n")
local q     = sh.Pipeline(first, sh.Command("head", "-n", 1))
print(q)                              -- sort | head -n 1
print(q:run())                        -- a

-- Arguments that need quoting are quoted in the rendering only; the
-- program receives them verbatim.
print(sh.Command("echo", "it's", "two words"))   -- echo 'it'\''s' 'two words'

-- Every Result remembers what produced it.
local r = sh.seq(1, 10):grep("5"):wc("-l")
print(r.__pipeline)                   -- seq 1 10 | grep 5 | wc -l

-- A Command is mutable; copy() takes a snapshot.
local base = sh.Command("git", "log")
local snap = base:copy()
base:flag("oneline")
print(snap, "/", base)                -- git log / git log --oneline
