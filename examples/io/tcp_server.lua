local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

local terminate = effect.new("terminate")

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
        local conn = listener:accept()
        fiber.spawn(function()
          conn:flush("Hello World!\n")
          conn:shutdown()
          local line = assert(conn:read(1024, "\n")):match("[^\r\n]*")
          if line == "" then
            print("Got empty request.")
          else
            print("Got request: " .. line)
          end
          conn:close()
        end)
      end
    end
  )
end

return runtime(main)
