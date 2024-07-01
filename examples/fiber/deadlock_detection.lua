local fiber = require "neumond.fiber"

local success, message = pcall(function()

  fiber.scope(function()
    local f1, f2
    f1 = fiber.spawn(function() f2:await() end)
    f2 = fiber.spawn(function() f1:await() end)
    return (f1:await()), (f2:await())
  end)

end)

assert(success == false)
print("Caught error: " .. tostring(message))
