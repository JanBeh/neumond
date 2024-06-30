local wait_posix_fiber = require "neumond.wait_posix_fiber"
local eio = require "neumond.eio"

wait_posix_fiber.main(
  function()
    eio.stdout:flush("Hello World!\n")
  end
)
