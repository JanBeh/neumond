local checkpoint = require "checkpoint"
local fiber = require "neumond.fiber"

local success = pcall(function()
  checkpoint(1)
  fiber.scope(function()
    local f1, f2
    f1 = fiber.spawn(function() f2:await() end)
    f2 = fiber.spawn(function() f1:await() end)
    checkpoint(2)
    return (f1:await()), (f2:await())
  end)

end)

assert(success == false)

checkpoint(3)
