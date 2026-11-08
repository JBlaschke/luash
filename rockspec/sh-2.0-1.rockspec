package = "sh"
version = "2.0-1"

source = {
    url = "git+https://github.com/JBlaschke/luash.git",
    tag = "v2.0.0",
}

description = {
    summary  = "Tiny library for shell scripting with Lua",
    detailed = [[
        Tiny library with syntax sugar for shell scripting in Lua (inspired by
        Python's sh module): every program on PATH is a function, its output
        is a value, and chains read like shell pipelines. It keeps stdout and
        stderr apart, reports exit status and signals, and implements cd,
        pushd and popd. Runs on Lua 5.1 to 5.5 and LuaJIT and needs no C
        module.

        Optional dependencies: programs are started through luaposix or luv
        when one of them is installed, and through Lua's own io.popen
        otherwise. Either one gives a faster backend that streams pipelines
        through pipes, and luv is the one that works on Windows. Install one
        of them next to sh:

            luarocks install luaposix
        or
            luarocks install luv

        Documentation: https://jblaschke.github.io/luash/ has runnable
        examples and a page on each part of how the library works.
        Source and issues: https://github.com/JBlaschke/luash
    ]],
    homepage = "https://jblaschke.github.io/luash/",
    license  = "MIT/X11",
}

-- luaposix and luv are optional. sh detects them at run time with
-- pcall(require, ...) and uses the first one available; without either it
-- falls back to io.popen. Install one of them for the faster backends.
dependencies = {
    "lua >= 5.1",
}

build = {
    type    = "builtin",
    modules = {
        ["sh"]               = "sh/init.lua",
        ["sh.command"]       = "sh/command.lua",
        ["sh.pipe"]          = "sh/pipe.lua",
        ["sh.sys"]           = "sh/sys.lua",
        ["sh.stack"]         = "sh/stack.lua",
        ["sh.backend"]       = "sh/backend/init.lua",
        ["sh.backend.posix"] = "sh/backend/posix.lua",
        ["sh.backend.luv"]   = "sh/backend/luv.lua",
        ["sh.backend.popen"] = "sh/backend/popen.lua",
    },
    install = {
        bin = {
            ["sh.autogen"] = "sh.autogen.lua",
        },
    },
}
