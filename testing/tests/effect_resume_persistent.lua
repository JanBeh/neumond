local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local interrupt = effect.new("interrupt")

local resume = effect.handle(
  {
    [interrupt] = function(resume)
      checkpoint(2, 5)
      return resume:persistent()
    end,
  },
  function()
    checkpoint(1)
    interrupt()
    checkpoint(4)
    interrupt()
    checkpoint(7)
  end
)
checkpoint(3)
resume = resume()
checkpoint(6)
resume = resume()

checkpoint(8)
