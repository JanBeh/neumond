local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local wait_posix_fiber = require "neumond.wait_posix_fiber"
local eio = require "neumond.eio"

wait_posix_fiber.main(function()
  local listener = assert(eio.tcplisten(nil, 1234))
  while true do
    local conn <close> = assert(listener:accept())
    local fib = fiber.spawn(function()
      wait.timeout(2)()
      print("Closing connection")
      conn:close()
    end)
    -- If the connection is closed while waiting for reading,
    -- an error will be thrown, because eio's close method
    -- invokes wait_posix.deregister_fd.
    print("Got:", conn:read(1024, "\n"))
    fib:kill()
  end
end)
