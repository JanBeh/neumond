local checkpoint = require "checkpoint"
local effect = require "neumond.effect"
local fiber = require "neumond.fiber"

local log = effect.new("log")

local function verbose(...)
  return effect.handle({
    [log] = function(resume, message)
      checkpoint(5, 8)
      return resume()
    end,
  }, ...)
end

local function quiet(...)
  return effect.handle({
    [log] = function(resume, message)
      checkpoint(11)
      return resume()
    end,
  }, ...)
end

local retval = fiber.scope(function()
  checkpoint(1)
  local value
  local producer, consumer
  local retval = verbose(function()
    checkpoint(2)
    return fiber.scope(function()
      producer = fiber.spawn(function()
        checkpoint(4)
        log("Started.")
        checkpoint(6)
        for i = 1, 5 do
          while value ~= nil do
            fiber.sleep()
          end
          value = i
          consumer:wake()
        end
        log("Finished.")
        return "producer"
      end)
      consumer = fiber.spawn(function()
        while not producer.results do
          while value == nil do
            fiber.sleep()
          end
          if value == 1 then checkpoint(7) end
          if value == 5 then checkpoint(9) end
          value = nil
          producer:wake()
        end
        return "consumer"
      end)
      checkpoint(3)
      producer:try_await()
      consumer:try_await()
      return "inner"
    end)
  end)
  assert(retval == "inner")
  checkpoint(10)
  quiet(function()
    log("This is quiet.") 
    assert(producer:await() == "producer")
    assert(consumer:await() == "consumer")
  end)
  return "outer"
end)

assert(retval == "outer")

checkpoint(12)
