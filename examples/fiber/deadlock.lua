local fiber = require "fiber"

fiber.main(function()
  local f1, f2
  f1 = fiber.spawn(function() f2:await() end)
  f2 = fiber.spawn(function() f1:await() end)
  return (f1:await()), (f2:await())
end)


