-- cd, pushd and popd are builtins: they change where the commands run.
local sh = require("sh")

print(sh.pwd())
sh.cd("tests")
print(sh.pwd())                        -- .../tests
sh.cd("..")

-- pushd and popd bracket a directory change; they chain like commands.
sh.pushd("sh") : ls("backend") : print()
sh.popd()
print(sh.pwd())                        -- back where we started

-- A directory that cannot be entered is reported, never raised, and the
-- input of the stage before passes through a builtin unchanged.
local r = sh.echo("passed through"):cd("/no/such/directory")
print(r.__exitcode, sh.stderr(r))
print(r:cat())                         -- passed through
