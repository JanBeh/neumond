local fiber = require "neumond.fiber"

local counter = 0

fiber.scope(function()
  fiber.spawn(function()
    -- endless loop:
    while true do
      counter = counter + 1
      fiber.yield()
    end
  end)
  for i = 1, 10 do
    fiber.yield()
  end
  -- fiber that prints "tick" gets killed when this function ends
end)

assert(counter == 10)
