local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local runtime = require "neumond.runtime"

function main(...)
  local a = wait.interval(1)
  local b = wait.interval(1.1)
  local c = wait.timeout(10)
  local f1 = fiber.spawn(function()
    while true do
      a()
      print("A")
    end
  end)
  local f2 = fiber.spawn(function()
    while true do
      b()
      print("B")
    end
  end)
  c()
  print("Done")
end

return runtime(main, ...)
