local effect = require "effect"
local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local waitio = require "waitio"
local eio = require "eio"

waitio_fiber.main(function()
  local listener = assert(eio.tcplisten(nil, 1234))
  while true do
    local conn <close> = assert(listener:accept())
    local fib = fiber.spawn(function()
      waitio.timeout(2)()
      print("Closing connection")
      conn:close()
    end)
    -- If the connection is closed while waiting for reading,
    -- an error will be thrown, because eio's close method
    -- invokes waitio.deregister_fd.
    print("Got:", conn:read(1024, "\n"))
    fib:kill()
  end
end)
