local sh = require "sh"
print("-- 1")
sh.pwd() : print()
print("-- 2")
sh.pushd("tests") : pwd() : print()
print("-- 3")
sh.popd() : pwd() : print()