local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"

fiber.main(
  waitio_fiber.main,
  function()
    print("reader started")
    fiber.yield()
    while true do
      print("reader waiting")
      waitio.wait_fd_read(0)
      print("reader woken")
      print("read: " .. tostring(io.stdin:read()))
    end
  end
)

