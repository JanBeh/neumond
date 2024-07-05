local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local cleanup = effect.new("cleanup")
local exit = effect.new("exit")

effect.handle(
  {
    [cleanup] = function(resume)
      return resume()
    end,
  },
  function()
    effect.handle(
      {
        [exit] = function(resume)
        end,
      },
      function()
        local guard <close> = setmetatable({}, {
          __close = function()
            cleanup()
          end,
        })
        exit()
        error("unreachable")
      end
    )
  end
)

checkpoint(1)
