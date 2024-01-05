local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local eio = require "eio"

fiber.main(
  waitio.provide,
  function()
    local listener = eio.tcplisten(nil, 1234)
    while true do
      local conn = listener:accept()
      fiber.spawn(function()
        conn:write("Hello\n")
        conn:close()
      end)
    end
  end
)
