-- A backend is a table with a name and six functions (docs/DESIGN.md,
-- section 4). This one wraps the backend in use and logs every run.
local sh      = require("sh")
local backend = require("sh.backend")   -- the registry

local real    = backend.current()
local logging = { name = "logging" }

-- The directory and the options stay with the real backend.
for _, f in ipairs({ "available", "configure", "chdir", "getcwd" }) do
    logging[f] = real[f]
end

function logging.capabilities()
    local caps = real.capabilities()
    caps.name  = logging.name
    return caps
end

function logging.run(argv, input, opts)
    io.stderr:write(
        "[", logging.name, "] ", table.concat(argv, " "),
        " (", #input, " bytes of input)\n"
    )
    return real.run(argv, input, opts)
end

sh.set_backend(logging)
print(sh.backend_name())                -- logging
print(sh.seq(1, 3):wc("-l"))            -- 3, with two log lines on stderr
