# Build the single-file library standalone/sh.lua and run the test matrix.
#
#   make             same as make standalone
#   make standalone  regenerate standalone/sh.lua from sh/ (never edit it)
#   make test        regenerate it, then run tests/run_all.sh
#   make clean       remove the generated file
#
# LUA names the interpreter that runs the build (make LUA=luajit).
# tests/run_all.sh picks its interpreters itself; LUASH_INTERPRETERS
# overrides the list.

LUA ?= lua

.PHONY: standalone test clean

# Always rebuilt: the build takes well under a second, and a rebuild cannot
# miss a module that was added to or removed from sh/.
standalone:
	$(LUA) opt/bin/build.lua

test: standalone
	tests/run_all.sh

clean:
	rm -f standalone/sh.lua standalone/sh.lua.tmp
