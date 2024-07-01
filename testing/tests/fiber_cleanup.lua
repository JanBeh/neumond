local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"

local user_exception = setmetatable({}, {
  __tostring = function() return "user exception" end,
})

local success, message = pcall(
  fiber.scope,
  function()
    fiber.spawn(function()
      checkpoint(2)
      local guard <close> = setmetatable({}, {
        __close = function()
          checkpoint(5)
        end,
      })
      checkpoint(3)
      fiber.sleep()
      error("unreachable")
    end)
    checkpoint(1)
    fiber.yield()
    checkpoint(4)
    error(user_exception)
  end
)

assert(success == false)
assert(message == user_exception)

checkpoint(6)
