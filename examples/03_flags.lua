-- Flags from tables, partial commands, and programs with tricky names.
local sh = require("sh")

-- String keys of a table are flags: a one-letter key gives -k, a longer
-- key gives --key; true gives the bare flag, false gives nothing, and a
-- string or number gives key=value. They come after the positional
-- entries of their table, sorted by key, so the command line is the same
-- on every run.
print(sh.sort({ __input = "10\n9\n100\n" }, { n = true, r = false }))

-- Build the arguments as data and look at the command line:
local c = sh.Command("tar", "-c", { file = "site.tar", verbose = true }, "docs")
print(c)                              -- tar -c --file=site.tar --verbose docs

-- When the order of flags matters, use positional strings or :flag().
print(sh.Command("ls"):flag("l"):flag("color", "never"))   -- ls -l --color=never

-- sh.command (lower case) returns a function with arguments preset:
local gitlog = sh.command("git", "log", "--oneline")
print(gitlog("-n", 1))

-- It also names programs that are not valid Lua identifiers, or are
-- keywords. sh(...) is the same as sh.command(...).
local truecmd = sh.command("true")
local pkgconf = sh("pkg-config")
print(truecmd().__exitcode, type(pkgconf))   -- 0  function

-- Shell builtins are not programs on PATH: run them through a shell. A
-- table groups several arguments; {"-c", "type type"} stays two words.
print(sh.sh("-c", "echo $0"))
print(sh("bash"){ "-c", "type type" })
