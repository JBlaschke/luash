# LuaSH

Shell scripting in Lua: every program on `PATH` is a function, its output
is a value, and chains read like shell pipelines.

```lua
local sh = require("sh")

print(sh.ls("-l"))                        -- run a program, print its output
print(sh.seq(1, 10):grep("5"):wc("-l"))   -- 1: stdout feeds the next stdin
print("I am " .. sh.whoami())             -- Results concatenate
sh.install()                              -- undefined globals become commands
print(wc(seq(1, 100), "-l"))              -- 100
```

LuaSH runs on Lua 5.1 to 5.5 and LuaJIT and needs no C module. Programs
start through [luaposix](https://luarocks.org/modules/gvvaughan/luaposix)
or [luv](https://luarocks.org/modules/luvit/luv) when one of them is
installed, and through Lua's own `io.popen` otherwise. Each command returns
a Result with stdout, stderr, the exit status, the signal and the pipeline
that produced it; a failing command raises, unless you ask it not to.

## Install

Any of these gives `require("sh")`:

```bash
luarocks install sh
```

```bash
curl -LO https://github.com/JBlaschke/luash/releases/latest/download/sh.lua
```

The second is the whole library in one file, attached to every
[release](https://github.com/JBlaschke/luash/releases); replace `latest`
with `download/v2.0.0` for a pinned version, and put the file anywhere on
`package.path`. In a clone, `standalone/sh.lua` is the same file. luaposix
and luv are optional:

```bash
luarocks install luaposix   # or: luarocks install luv
```

## Where to look

- [Examples](examples.md): nine short scripts, from the first call to a
  backend of your own, with their output.
- How it works, one page per topic, each linking the
  [design document](DESIGN.md) and the code on GitHub:
  [architecture](how-it-works/architecture.md),
  [pipes in each backend](how-it-works/pipes.md),
  [backend resolution](how-it-works/backends.md),
  [configuration and bundling](how-it-works/configuration.md),
  [commands as data](how-it-works/commands.md),
  [results, errors and output](how-it-works/results.md),
  [working directory](how-it-works/cwd.md), and
  [testing and your own backend](how-it-works/testing.md).
- The [design document](DESIGN.md) and the
  [implementation plan](PLAN.md) that LuaSH 2.0 was built from.
- The [README](https://github.com/JBlaschke/luash#readme) is the reference
  for the API.

## Backends at a glance

| Backend | Needs | stdin | stderr | Signals |
|---|---|---|---|---|
| `posix` | luaposix | yes | separate | yes |
| `luv` | luv | yes | separate | yes |
| `popen` | `io.popen` only | depends on the strategy | depends on the strategy | no |

The first available one in the platform's order is used; `sh.backend_name()`
tells which, and `sh.set_backend("popen", { strategy = "standard" })`
switches. [Backend resolution](how-it-works/backends.md) has the details.
