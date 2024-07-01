local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local interrupt = effect.new("interrupt")

local resume = effect.handle(
  {
    [interrupt] = function(resume)
      checkpoint(2)
      return resume:persistent()
    end,
  },
  function()
    checkpoint(1)
    interrupt()
    checkpoint(4)
  end
)
checkpoint(3)
resume()

checkpoint(5)
