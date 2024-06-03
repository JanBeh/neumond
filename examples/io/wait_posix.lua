local effect = require "effect"
local fiber = require "fiber"
local wait_posix = require "wait_posix"
local wait_posix_fiber = require "wait_posix_fiber"

fiber.main(
  wait_posix_fiber.main,
  function()
    print("reader started")
    fiber.yield()
    while true do
      print("reader waiting")
      wait_posix.wait_fd_read(0)
      print("reader woken")
      print("read: " .. assert(io.stdin:read()))
    end
  end
)
