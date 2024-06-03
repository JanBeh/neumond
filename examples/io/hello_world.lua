local wait_posix_fiber = require "wait_posix_fiber"
local eio = require "eio"

wait_posix_fiber.main(
  function()
    eio.stdout:flush("Hello World!\n")
  end
)
