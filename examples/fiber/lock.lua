local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local wait_posix_fiber = require "neumond.wait.posix.fiber"

local lock = wait.mutex()

return wait_posix_fiber.main(function()
  local f1 = fiber.spawn(function()
    for i = 1, 2 do
      print("Fiber A", i)
      fiber.yield()
    end
    local guard <close> = lock()
    for i = 3, 5 do
      print("Fiber A", i)
      fiber.yield()
    end
  end)
  local f2 = fiber.spawn(function()
    for i = 1, 5 do
      do
        local guard <close> = lock()
        print("Fiber B", i)
      end
      fiber.yield()
    end
  end)
  return f1:await(), f2:await()
end)
