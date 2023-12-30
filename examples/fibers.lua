local fiber = require "fiber"
local effect = fiber.effect_mod -- use modified "effect" module from "fiber"

local log = effect.new("log")

local function logging(...)
  return effect.handle({
    [log] = function(resume, message)
      print("LOG: " .. tostring(message))
      return resume()
    end,
  }, ...)
end

local function silence(...)
  return effect.handle({
    [log] = function(resume, message)
      return resume()
    end,
  }, ...)
end

local retval = fiber.main(function()
  local v
  local producer, consumer
  local retval = logging(function()
    producer = fiber.spawn(function()
      log("Producer started")
      for i = 1, 10 do
        while v ~= nil do
          fiber.sleep()
        end
        v = i
        consumer:wake()
      end
      log("Producer finished")
      return "Producer finished"
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
      return "Consumer finished"
    end)
    return "Logging block done"
  end)
  assert(retval == "Logging block done")
  silence(function()
    fiber.spawn(function()
      log("This is not logged")
      local result = producer:await()
      print("Awaited value: " .. result)
      local result = consumer:await()
      print("Awaited value: " .. result)
    end)
  end)
  return "Done"
end)

print("Retval: " .. retval)
