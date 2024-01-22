-- This code causes an unhandled early return marker error:

local effect = require "effect"

local eff1 = effect.new("eff1")
local eff2 = effect.new("eff2")

effect.handle(
  {
    [eff1] = function(resume)
    end,
  },
  function()
    effect.handle(
      {
        [eff2] = function(resume)
          eff1()
          return resume()
        end,
      },
      function()
        local cleanup <close> = setmetatable({}, {
          __close = function()
            print("Cleaning up")
          end,
        })
        eff2()
        print("unreachable")
      end
    )
  end
)