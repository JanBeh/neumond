local effect = require "effect"

local eff1 = effect.new("eff1")
local eff2 = effect.new("eff2")

effect.handle(
  {
    [eff1] = function(resume)
      local cleanup <close> = setmetatable({}, {
        __close = function()
          print("Cleaning up eff1 handler.")
        end,
      })
      -- eff1 handler doesn't resume
    end,
  },
  function()
    effect.handle(
      {
        [eff2] = function(resume)
          local cleanup <close> = setmetatable({}, {
            __close = function()
              print("Cleaning up eff2 handler.")
            end,
          })
          eff1() -- this causes eff2 to not resume
          return resume()
        end,
      },
      function()
        local cleanup <close> = setmetatable({}, {
          __close = function()
            print("Cleaning up inner action.")
          end,
        })
        eff2()
        print("unreachable")
      end
    )
  end
)
