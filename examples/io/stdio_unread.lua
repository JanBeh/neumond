local wait_posix_fiber = require "neumond.wait_posix_fiber"
local eio = require "neumond.eio"

eio.stdin:unread("Some more...")
eio.stdin:unread("Hello World!\n")

wait_posix_fiber.main(
  function()
    while true do
      local line = assert(eio.stdin:read(40, "\n"))
      if line == "" then
        break
      end
      eio.stdout:flush("Got: ", line, "\n")
    end
    eio.stdout:flush("EOF\n")
  end
)
