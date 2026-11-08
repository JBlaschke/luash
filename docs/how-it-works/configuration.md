# Configuration and bundling

## `sh.config`

All settings live in one table, [`settings`][settings], which `sh.config`
names. The defaults ([section 3.2](../DESIGN.md#32-configuration)):

```lua
sh.config = {
    verbose      = false,   -- stream child output live
    trace        = false,   -- print "+ <pipeline>" before each run
    raise_errors = true,    -- error() when a command fails
    backend      = "auto",  -- "auto" | "posix" | "luv" | "popen"
    popen        = {
        strategy = "auto",  -- "auto" | "shmem" | "standard" | "basic" | "minimal"
        tmpdir   = nil,     -- root for temp files; nil: TMPDIR, TMP, TEMP, /tmp
    },
    sink         = nil,     -- function(stream, chunk) for verbose and trace
}
```

There are two kinds of field. `verbose`, `trace`, `raise_errors` and
`sink` are read at every run by [`pipe.run`][pipe_run] and
[`execute`][execute], so setting one takes effect at the next command.
`backend` and `popen` are read only when a backend is selected: at load,
by `sh.set_backend()`, or when a whole table is assigned to `sh.config`.
After `sh.config.backend = "popen"`, call `sh.set_backend()` without
arguments to select it.

The module table has no raw `config` field. Its metatable maps the name:
[`index_module`][index_module] returns the settings table, and
[`newindex_module`][newindex_module] routes an assignment to
[`apply_config`][apply_config], which selects the backend the new table
names, hands the table to the run path ([`pipe.set_config`][set_config])
and only then replaces the old one; an unavailable backend raises and
changes nothing. The 1.x names `sh.__verbose` and `sh.__raise_errors` are
[aliases][ALIASES] of two fields.

[`sh.set_backend(choice, opts)`][set_backend] selects now and records the
choice in `sh.config`; `opts` are popen's `strategy` and `tmpdir`, on top
of `sh.config.popen`. `LUASH_BACKEND` and `LUASH_POPEN_STRATEGY` override a
value of `"auto"` and are read once, when the registry loads
([backend resolution](backends.md)).

## Installing

Three ways, each giving `require("sh")`:

- **luarocks**: `luarocks install sh` installs the module directory from
  [`rockspec/sh-2.0-1.rockspec`][rockspec]; in a clone,
  `luarocks make rockspec/sh-scm-3.rockspec`. The only dependency is Lua
  itself; luaposix and luv are optional rocks that unlock the faster
  backends.
- **One file**: copy [`standalone/sh.lua`][standalone] anywhere on
  `package.path`. Every [release](https://github.com/JBlaschke/luash/releases)
  carries it as the asset `sh.lua`, so a specific version is one download:

  ```bash
  curl -LO https://github.com/JBlaschke/luash/releases/download/v2.0.0/sh.lua
  ```

- **A clone**: put `./?/init.lua;./?.lua` in `LUA_PATH`, as
  [`examples/run_all.sh`][examples_run] and the test matrix do.

## How the single file is built

`make standalone` runs [`opt/bin/build.lua`][build], which needs only the
Lua standard library and `find`. [`scan_modules`][scan_modules] lists every
file under `sh/`, so a new module cannot be left out, and the vendored
[amalg][amalg] bundles them with `sh/init.lua` as the main chunk:

```
amalg -o standalone/sh.lua -s sh/init.lua sh.backend sh.backend.luv ... sh.sys
```

Each module becomes a `package.preload["sh.x"]` entry, so a
`require("sh.backend")` inside the bundle resolves without touching the
file system, and the chunk ends with `init.lua`'s `return M`, which is what
`require("sh")` gets. `posix` and `luv` are never embedded: they are C
modules, their `require` calls stay inside `pcall` and resolve on the host
at run time. [Section 8](../DESIGN.md#8-standalone-single-file-library)
makes that a gating requirement, checked by running the test suite with
`package.cpath = ""` and by a grep that every `require("posix")` or
`require("luv")` in the file sits on a `pcall` line.

The generated file is committed and never edited. The
[release workflow][release] rebuilds it from the tagged sources, fails when
the result differs from the committed file, and attaches it to the release.

[settings]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L42
[pipe_run]: https://github.com/JBlaschke/luash/blob/master/sh/pipe.lua#L63
[execute]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L196
[index_module]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L445
[newindex_module]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L456
[apply_config]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L70
[set_config]: https://github.com/JBlaschke/luash/blob/master/sh/pipe.lua#L49
[ALIASES]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L56
[set_backend]: https://github.com/JBlaschke/luash/blob/master/sh/init.lua#L414
[rockspec]: https://github.com/JBlaschke/luash/blob/master/rockspec/sh-2.0-1.rockspec
[standalone]: https://github.com/JBlaschke/luash/blob/master/standalone/sh.lua
[examples_run]: https://github.com/JBlaschke/luash/blob/master/examples/run_all.sh
[build]: https://github.com/JBlaschke/luash/blob/master/opt/bin/build.lua
[scan_modules]: https://github.com/JBlaschke/luash/blob/master/opt/bin/build.lua#L80
[amalg]: https://github.com/JBlaschke/luash/blob/master/opt/bin/build/amalg.lua
[release]: https://github.com/JBlaschke/luash/blob/master/.github/workflows/release.yml
