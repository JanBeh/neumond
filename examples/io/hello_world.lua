local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

waitio_fiber.main(
  function()
    eio.stdout:flush("Hello World!\n")
  end
)
