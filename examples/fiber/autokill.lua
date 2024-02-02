local fiber = require "fiber"

fiber.main(function()
  fiber.autokill(function()
    fiber.spawn(function()
      while true do
        print("tick")
        fiber.yield()
      end
    end)
    for i = 1, 10 do
      print("#" .. i)
      fiber.yield()
    end
  end)
end)
