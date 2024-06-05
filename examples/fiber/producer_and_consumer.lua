local effect = require "effect"
local fiber = require "fiber"

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

local retval = fiber.scope(function()
  local v
  local producer, consumer
  local retval = logging(function()
    return fiber.scope(function()
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
      producer:try_await()
      consumer:try_await()
      return "Inner block done"
    end)
  end)
  assert(retval == "Inner block done")
  silence(function()
    log("This is not logged")
    local result = producer:await()
    print("Awaited value: " .. result)
    local result = consumer:await()
    print("Awaited value: " .. result)
  end)
  return "Done"
end)

print("Retval: " .. retval)
