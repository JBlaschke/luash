-- Run programs as functions and read their output.
local sh = require("sh")

-- Every program on PATH is a function of the module. The arguments
-- become the program's arguments, and the call returns a Result.
print(sh.uname("-s"))              -- Darwin, Linux, ...
print(sh.echo("hello", "world"))   -- hello world

-- A Result prints as its trimmed stdout and concatenates with `..`.
print("I am " .. sh.whoami())

-- The raw fields are there too.
local r = sh.printf("%s\n", "line one", "line two")
io.write(r.__stdout)               -- line one / line two, with newlines
print(r.__exitcode)                -- 0
print(sh.stdout(r) == r.__stdout)  -- true

-- Walk the lines of an output.
for line in sh.seq(1, 3).__stdout:gmatch("[^\n]+") do
    print("got", line)
end

-- sh.install() makes undefined globals commands: ls("-l") is sh.ls("-l").
sh.install()
print(wc(seq(1, 100), "-l"))       -- 100
