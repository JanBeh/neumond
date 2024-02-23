local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"

waitio_fiber.main(function()
  local a = waitio.interval(1)
  local b = waitio.interval(1.1)
  local f1 = fiber.spawn(function()
    while true do
      a()
      print("A")
    end
  end)
  local f2 = fiber.spawn(function()
    while true do
      b()
      print("B")
    end
  end)
  f1:await()
  f2:await()
end)
