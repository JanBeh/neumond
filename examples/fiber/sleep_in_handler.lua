local effect = require "effect"
local fiber = require "fiber"

fiber.main(function()
  local mysleep = effect.new("mysleep")
  local mywake = effect.new("mywake")
  local sleeping_fiber
  fiber.handle_spawned(
    {
      [mysleep] = function(resume)
        sleeping_fiber = fiber.current()
        fiber.sleep()
        return resume()
      end,
      [mywake] = function(resume)
        if sleeping_fiber then
          sleeping_fiber:wake()
          sleeping_fiber = nil
        end
        return resume()
      end,
    },
    function()
      fiber.spawn(function()
        print("Execute 1")
        mysleep()
        print("Execute 4")
      end)
      fiber.spawn(function()
        print("Execute 2")
        mywake()
        print("Execute 3")
      end)
    end
  )
end)
