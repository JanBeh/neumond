local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local outer = effect.new("outer")
local inner = effect.new("inner")

effect.handle(
  {
    [outer] = function(resume, value)
      checkpoint(2, 6)
      return resume(value + 1)
    end,
  },
  function()
    effect.handle(
      {
        [inner] = function(resume)
          checkpoint(4)
          return resume("inner")
        end,
      },
      function()
        checkpoint(1)
        assert(outer(5) == 6)
        checkpoint(3)
        assert(inner() == "inner")
        checkpoint(5)
        assert(outer(8) == 9)
        checkpoint(7)
      end
    )
  end
)

checkpoint(8)
