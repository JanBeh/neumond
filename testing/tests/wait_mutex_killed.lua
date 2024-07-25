local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local runtime = require "neumond.runtime"

runtime(function()
  checkpoint(1)
  local lock = wait.mutex()
  local f1 = fiber.spawn(function()
    checkpoint(3)
    local guard <close> = lock()
    error("unreachable")
  end)
  local f2 = fiber.spawn(function()
    checkpoint(4)
    local guard <close> = lock()
    checkpoint(7)
  end)
  do
    local guard <close> = lock()
    checkpoint(2)
    fiber.yield()
    checkpoint(5)
    f1:kill()
  end
  checkpoint(6)
  return f2:await()
end)

checkpoint(8)
