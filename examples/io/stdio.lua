local effect = require "effect"
local fiber = require "fiber"
local eio = require "eio"

fiber.main(
  eio.main,
  function()
    while true do
      local line, errmsg = eio.stdin:read(40, "\n")
      if line == false then
        break
      end
      if not line then
        error(errmsg)
      end
      eio.stdout:write("Got: " .. line .. "\n")
    end
    eio.stdout:write("EOF\n")
  end
)
