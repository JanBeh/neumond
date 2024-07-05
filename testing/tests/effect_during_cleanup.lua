local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local cleanup = effect.new("cleanup")
local exit = effect.new("exit")

effect.handle(
  {
    [cleanup] = function(resume)
      checkpoint(4)
      return resume()
    end,
  },
  function()
    effect.handle(
      {
        [exit] = function(resume)
          checkpoint(2)
        end,
      },
      function()
        checkpoint(1)
        local guard <close> = setmetatable({}, {
          __close = function()
            checkpoint(3)
            cleanup()
            checkpoint(5)
          end,
        })
        exit()
        error("unreachable")
      end
    )
  end
)

checkpoint(6)
