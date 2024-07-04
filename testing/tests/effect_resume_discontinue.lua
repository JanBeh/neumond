local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local exit = effect.new("exit")

effect.handle(
  {
    [exit] = function(resume)
      checkpoint(3)
      -- Exiting from effect handler does not require manual discontinuation.
    end,
  },
  function()
    checkpoint(1)
    local guard <close> = setmetatable({}, {
      __close = function()
        checkpoint(4)
      end,
    })
    checkpoint(2)
    exit()
    error("unreachable")
  end
)

checkpoint(5)

local resume = effect.handle(
  {
    [exit] = function(resume)
      checkpoint(8)
      -- resume:persistent() will disable auto-discontinuation:
      return resume:persistent()
    end,
  },
  function()
    checkpoint(6)
    local cleanup <close> = setmetatable({}, {
      __close = function()
        checkpoint(10)
      end,
    })
    checkpoint(7)
    exit()
    error("unreachable")
  end
)
checkpoint(9)
resume:discontinue()

checkpoint(11)
