local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"

local function new_lock()
  -- This function does not need to know about fibers but uses waitio.waiter.
  local locked = false
  local waiters = {}
  local guard = setmetatable({}, {
    __close = function()
      locked = false
      local w = table.remove(waiters, 1)
      if w then
        w.ready = true
      end
    end,
  })
  return function()
    if locked then
      local w = waitio.waiter()
      waiters[#waiters+1] = w
      w()
    end
    locked = true
    return guard
  end
end

local lock = new_lock()

return waitio_fiber.main(function()
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
