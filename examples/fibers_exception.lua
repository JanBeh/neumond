local fiber = require "fiber"
local effect = fiber.effect_mod

local exception = effect.new("exception")

local retval = fiber.main(function()
  local v
  local producer, consumer
  local retval = effect.handle(
    {
      [exception] = function(resume)
        return "ERROR"
      end,
    },
    function()
      fiber.spawn(function()
        while fiber.other() do
          print("tick")
          fiber.yield()
        end
      end)
      producer = fiber.spawn(function()
        for i = 1, 10 do
          if i == 5 then
            exception()
          end
          while v ~= nil do
            fiber.sleep()
          end
          v = i
          consumer:wake()
        end
      end)
      consumer = fiber.spawn(function()
        while producer.results == nil do
          while v == nil do
            fiber.sleep()
          end
          print(v)
          v = nil
          producer:wake()
        end
      end)
      return "OK"
    end
  )
  return retval
end)

assert(retval == "ERROR")
