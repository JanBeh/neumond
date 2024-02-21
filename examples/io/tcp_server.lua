local effect = require "effect"
local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

local terminate = effect.new("terminate")

waitio_fiber.main(
  function()
    fiber.handle(
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
          local conn = listener:accept()
          fiber.spawn(function()
            conn:flush("Hello World!\n")
            conn:shutdown()
            local line = assert(conn:read(1024, "\n"))
            print("Got: " .. tostring(line))
            conn:close()
          end)
        end
      end
    )
  end
)
