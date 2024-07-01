local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local iterations = 2e6 -- use 1e7 to be sure, but 2e6 is faster

local increment = effect.new("increment")
local counter = 0

effect.handle(
  {
    [increment] = function(resume)
      counter = counter + 1
      return resume()
    end,
  },
  function()
    checkpoint(1)
    for i = 1, iterations do
      increment()
    end
    checkpoint(2)
  end
)
assert(counter == iterations)

checkpoint(3)
