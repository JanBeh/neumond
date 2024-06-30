local effect = require "neumond.effect"
local fiber = require "neumond.fiber"

local exception = effect.new("exception")

local retval = fiber.scope(function()
  local v
  local producer, consumer
  local retval = fiber.handle(
    {
      [exception] = function(resume)
        return "ERROR"
      end,
    },
    function()
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
      producer:await()
      consumer:await()
      return "OK"
    end
  )
  return retval
end)

assert(retval == "ERROR")
