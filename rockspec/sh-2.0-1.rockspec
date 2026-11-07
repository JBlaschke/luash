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
        Python's sh module). Runs programs through luaposix, luv or io.popen,
        whichever the host provides.
    ]],
    homepage = "https://github.com/JBlaschke/luash",
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
