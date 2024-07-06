local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

local terminate = effect.new("terminate")
local timeout = effect.new("timeout")
local client_ioerr = effect.new("client_ioerr")

local function assert_io(first, ...)
  if first then
    return first, ...
  else
    client_ioerr(...)
  end
end

local client_ioerr_handlers = {
  [client_ioerr] = function(resume, message)
    print("Client I/O error: " .. tostring(message))
  end,
}

local function handle_client_ioerr(...)
  return fiber.handle(client_ioerr_handlers, ...)
end

local function main(...)
  return fiber.handle(
    {
      [terminate] = function(resume)
        print("Terminating.")
      end,
    },
    function()
      fiber.spawn(function() eio.catch_signal(2)(); terminate() end)
      fiber.spawn(function() eio.catch_signal(15)(); terminate() end)
      local listener = assert(eio.tcplisten(nil, 1234))
      while true do
        local conn = assert(listener:accept())
        fiber.spawn(handle_client_ioerr, function()
          local conn <close> = conn
          assert_io(conn:flush("Hello, what is your name?\n"))
          local name = (
            assert_io(conn:read(1024, "\n"))
            :match("^[ \t\r\n]*(.-)[ \t\r\n]*$")
          )
          if name == "" then
            assert_io(conn:flush("You didn't provide a name, bye.\n"))
          else
            assert_io(conn:flush("Hello " .. name .. "!\n"))
            assert_io(conn:flush("You may send some final data now.\n"))
            assert_io(conn:shutdown())
            local data = assert_io(conn:read(1024))
            if data == "" then
              print("Got no data.")
            else
              print("Got some data: " .. data)
            end
          end
        end)
      end
    end
  )
end

return runtime(main)
