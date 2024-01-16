local fiber = require "fiber"

fiber.main(function()
  local a, b
  a = fiber.spawn(function()
    for i = 1, 10 do
      print("Fiber A: " .. i)
      if i >= 5 then
        b:kill()
      end
      if i >= 8 then
        a:kill()
        print("unreachable")
      end
      fiber.yield()
    end
  end)
  b = fiber.spawn(function()
    for i = 1, 10 do
      print("Fiber B: " .. i)
      fiber.yield()
    end
  end)
end)
