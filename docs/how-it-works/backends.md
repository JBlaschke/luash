# Backend resolution

The registry, [`sh/backend/init.lua`][registry], is the only module that
knows which backends exist. Its rule, from
[section 6.6](../DESIGN.md#66-registry-shbackendinitlua): resolve once, look
up, never re-detect.

## When a backend is selected

Three moments call [`select`][select]:

1. `require("sh")`, [inside `pcall`][init_select], so that a host with no
   usable backend still loads the module and the first command raises the
   recorded reason ([`current`][current]);
2. [`sh.set_backend(choice, opts)`][set_backend];
3. an assignment `sh.config = { ... }`, which [`apply_config`][apply_config]
   turns into a selection of the backend the table names.

A command or a `cd` never probes anything: [`run`][backend_run],
[`chdir`][backend_chdir], [`getcwd`][backend_getcwd] and
[`capabilities`][backend_caps] go straight to the backend in use.

## What a choice means

[`resolve`][resolve] dispatches on the type of the choice through
[`RESOLVE`][RESOLVE]:

- A **table** of your own ([`RESOLVE.table`][resolve_table]) is checked
  against the contract and used as it is; see
  [testing and your own backend](testing.md).
- A **name** ([`RESOLVE.string`][resolve_string]) loads
  `sh.backend.<name>` with [`load`][load].
- **`"auto"`** or nil is `LUASH_BACKEND` when that is set and not empty or
  `"auto"`, otherwise the first candidate of the platform's order that works
  ([`first_available`][first_available]).

The order is one table, [`ORDER`][ORDER], keyed by
[`sys.platform()`][platform]: `posix, luv, popen` on POSIX systems,
`luv, popen` on Windows, and `luv, posix, popen` on Android, where `fork`
inside an app process is unsupported.

## What "works" means

[`candidate`][candidate] accepts a backend when three checks pass:

1. the module loads ([`load`][load]); a failed load is tried again at the
   next selection, so a library installed later is found;
2. it is complete: a string `name` and the six functions of
   [`CONTRACT`][CONTRACT], checked by [`incomplete`][incomplete], which
   names what is missing;
3. [`ready`][ready]: `configure(opts)` is called, then `available()` must
   return true.

`configure` runs before `available` because popen's answer depends on its
strategy: `minimal` works almost anywhere, `shmem` only with a writable
`/dev/shm`. The options are the popen options of `sh.config` with those of
the call on top ([`popen_options`][popen_options]);
[`configuration`][configuration] replaces a strategy of `"auto"` with
`LUASH_POPEN_STRATEGY`. Both environment variables are read once, when the
registry loads ([`ENV`][ENV]), and exist for the test matrix and operators.

All three checks run through [`sys.load_pcall`][load_pcall], so that a
library loading while `sh.install()` is active still sees undefined
globals as nil.

## Failure

A named backend that does not work is an error naming it and the reason,
such as `sh.backend: luv is unavailable: module 'luv' not found`; with
`"auto"` and nothing available, the error lists every candidate's reason.
In both cases the backend in use stays as it was: [`select`][select]
configures it again with its previous options, since the failed attempt may
have reconfigured popen. `sh.config` is updated only after a selection
succeeded ([`set_backend`][set_backend]).

## Listing and preloading

[`available`][available] reports the platform's backends that pass the
checks with the options of the backend in use, computed once per selection;
`sh.available_backends()` returns it. [`preload`][preload] loads every
backend of the platform without selecting one. `sh.install()` calls it
first, so that a script's own `require("posix")` after `install()` gets the
loaded module, as with the 1.x library.

[registry]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua
[select]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L204
[init_select]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L479
[current]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L226
[set_backend]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L414
[apply_config]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L70
[backend_run]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L249
[backend_chdir]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L257
[backend_getcwd]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L267
[backend_caps]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L239
[resolve]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L188
[RESOLVE]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L163
[resolve_table]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L166
[resolve_string]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L176
[load]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L98
[first_available]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L149
[ORDER]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L33
[platform]: https://github.com/JBlaschke/luash/blob/main/sh/sys.lua#L33
[candidate]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L134
[CONTRACT]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L41
[incomplete]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L110
[ready]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L124
[popen_options]: https://github.com/JBlaschke/luash/blob/main/sh/init.lua#L80
[configuration]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L66
[ENV]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L52
[load_pcall]: https://github.com/JBlaschke/luash/blob/main/sh/sys.lua#L26
[available]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L275
[preload]: https://github.com/JBlaschke/luash/blob/main/sh/backend/init.lua#L292
