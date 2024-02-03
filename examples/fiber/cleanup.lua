local fiber = require "fiber"

local user_exception = setmetatable({}, {
  __tostring = function() return "user exception" end,
})

local success, message = pcall(function()

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
    error(user_exception)
  end)

end)

assert(success == false)
assert(message == user_exception)
