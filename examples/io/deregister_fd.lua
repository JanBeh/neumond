local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

local function main(...)
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
end

return runtime(main, ...)
