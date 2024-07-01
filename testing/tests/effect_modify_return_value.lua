local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local increment_result = effect.new("increment_result")

local function foo()
  checkpoint(2)
  increment_result("Hello")
  checkpoint(4)
end

local retval = effect.handle(
  {
    [increment_result] = function(resume, message)
      checkpoint(3)
      assert(message == "Hello")
      return resume() + 1
    end,
  },
  function()
    checkpoint(1)
    foo()
    checkpoint(5)
    return 100
  end
)

assert(retval == 101)
