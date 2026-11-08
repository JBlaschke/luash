-- See which backend runs your commands, and pick another one.
local sh = require("sh")

print("in use:    " .. sh.backend_name())
print("available: " .. table.concat(sh.available_backends(), " "))

-- What the backend in use can do.
local caps = sh.capabilities()
local keys = {}
for key in pairs(caps) do keys[#keys + 1] = key end
table.sort(keys)
for _, key in ipairs(keys) do print(key, caps[key]) end

-- Select a backend now; it raises when that one is unavailable here, and
-- the backend in use then stays as it was.
local ok, err = pcall(sh.set_backend, "popen", { strategy = "standard" })
if ok then
    print("now using " .. sh.backend_name() .. "/" .. sh.capabilities().strategy)
else
    print(err)
end
print(sh.echo("still works"))

-- A popen strategy that merges stderr into stdout.
sh.set_backend("popen", { strategy = "basic" })
print(sh.sh("-c", "echo out; echo err >&2"))

-- Back to the platform's default. sh.config records every selection.
sh.set_backend("auto", { strategy = "auto" })
print(sh.backend_name(), sh.config.backend, sh.config.popen.strategy)
