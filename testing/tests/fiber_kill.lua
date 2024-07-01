local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"

fiber.scope(function()
  local a, b
  a = fiber.spawn(function()
    for i = 1, 10 do
      checkpoint(1, 3, 5, 7, 9, 10, 11, 12)
      if i >= 5 then
        b:kill()
      end
      if i >= 8 then
        a:kill()
        error("unreachable")
      end
      fiber.yield()
    end
  end)
  b = fiber.spawn(function()
    for i = 1, 10 do
      checkpoint(2, 4, 6, 8, 10)
      fiber.yield()
    end
  end)
  a:try_await()
  b:try_await()
end)

checkpoint(13)
