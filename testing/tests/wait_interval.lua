local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local runtime = require "neumond.runtime"

runtime(function()
  local tmr1 = wait.interval(0.02 * 5)
  local tmr2 = wait.interval(0.02 * 8)
  local tmr3 = wait.timeout(0.02 * 36)
  local task1 = fiber.spawn(function()
    while true do
      tmr1()
      checkpoint(2, 4, 5, 7, 9, 10, 12)
    end
  end)
  local task2 = fiber.spawn(function()
    while true do
      tmr2()
      checkpoint(3, 6, 8, 11)
    end
  end)
  checkpoint(1)
  tmr3()
end)

checkpoint(13)
