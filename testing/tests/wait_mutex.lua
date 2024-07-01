local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local runtime = require "neumond.runtime"

runtime(function()
  local lock = wait.mutex()
  checkpoint(1)
  local f1 = fiber.spawn(function()
    for i = 1, 2 do
      checkpoint(3, 6)
      fiber.yield()
    end
    checkpoint(9)
    local guard <close> = lock()
    checkpoint(10)
    for i = 3, 5 do
      checkpoint(11, 13, 14)
      fiber.yield()
    end
  end)
  local f2 = fiber.spawn(function()
    for i = 1, 5 do
      checkpoint(4, 7, 12, 16, 18)
      do
        local guard <close> = lock()
      end
      checkpoint(5, 8, 15, 17, 19)
      fiber.yield()
    end
  end)
  checkpoint(2)
  return f1:await(), f2:await()
end)

checkpoint(20)
