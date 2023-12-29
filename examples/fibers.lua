local fiber = require "fiber"

local retval = fiber.main(function()
  local v
  local producer, consumer
  producer = fiber.spawn(function()
    for i = 1, 10 do
      while v ~= nil do
        fiber.sleep()
      end
      v = i
      consumer:wake()
    end
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
  local x = fiber.spawn(function()
    local result = producer:await()
    print("Awaited value: " .. result)
    local result = consumer:await()
    print("Awaited value: " .. result)
  end)
  return "Done"
end)

print("Retval: " .. retval)
