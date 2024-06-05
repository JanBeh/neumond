local fiber = require "fiber"

fiber.scope(function()
  fiber.spawn(function()
    -- endless loop:
    while true do
      print("tick")
      fiber.yield()
    end
  end)
  for i = 1, 10 do
    print("#" .. i)
    fiber.yield()
  end
  -- fiber that prints "tick" gets killed when this function ends
end)
