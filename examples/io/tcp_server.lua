local effect = require "effect"
local fiber = require "fiber"
local eio = require "eio"

fiber.main(
  eio.main,
  function()
    local listener = assert(eio.tcplisten(nil, 1234))
    while true do
      local conn = listener:accept()
      fiber.spawn(function()
        conn:write("Hello World!\n")
        conn:flush()
        conn:close()
      end)
    end
  end
)
