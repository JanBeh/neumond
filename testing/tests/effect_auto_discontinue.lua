local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local eff1 = effect.new("eff1")
local eff2 = effect.new("eff2")

effect.handle(
  {
    [eff1] = function(resume)
      checkpoint(5)
      local guard <close> = setmetatable({}, {
        __close = function()
          checkpoint(7)
        end,
      })
      checkpoint(6)
      -- eff1 handler doesn't resume
    end,
  },
  function()
    effect.handle(
      {
        [eff2] = function(resume)
          checkpoint(3)
          local guard <close> = setmetatable({}, {
            __close = function()
              checkpoint(8)
            end,
          })
          checkpoint(4)
          eff1() -- this causes eff2 to not resume
          return resume()
        end,
      },
      function()
        checkpoint(1)
        local guard <close> = setmetatable({}, {
          __close = function()
            checkpoint(9)
          end,
        })
        checkpoint(2)
        eff2()
        error("unreachable")
      end
    )
  end
)

checkpoint(10)
