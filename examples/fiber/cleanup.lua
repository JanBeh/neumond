local fiber = require "fiber"

return fiber.main(function()
  fiber.spawn(function()
    local guard <close> = setmetatable({}, {
      __close = function()
        print("Cleanup")
      end,
    })
    print("Installed guard")
    fiber.sleep()
    print("unreachable")
  end)
  fiber.yield()
  error("user exception")
end)
