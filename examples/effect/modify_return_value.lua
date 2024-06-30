local effect = require "neumond.effect"

local increment_result = effect.new("increment_result")

local function foo()
  increment_result("Hello")
end

local retval = effect.handle(
  {
    [increment_result] = function(resume, message)
      print(message)
      return resume() + 1
    end,
  },
  function()
    foo()
    print("World")
    return 5
  end
)

assert(retval == 6)
