local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

waitio_fiber.main(
  function()
    while true do
      local line, errmsg = eio.stdin:read(40, "\n")
      if line == false then
        break
      end
      if not line then
        error(errmsg)
      end
      eio.stdout:flush("Got: " .. line .. "\n")
    end
    eio.stdout:flush("EOF\n")
  end
)
