local fiber = require "neumond.fiber"

fiber.scope(function()
  local task1 = fiber.spawn(function()
    for i = 1, 3 do
      print("tick " .. i)
      fiber.yield()
    end
  end)
  local task2 = fiber.spawn(function()
    for i = 1, 3 do
      print("tock " .. i)
      fiber.yield()
    end
  end)
  task1:try_await()
  task2:try_await()
end)
