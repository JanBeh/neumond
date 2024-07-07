local effect = require "neumond.effect"

local fail = effect.new("fail")

local function foo()
  fail()
end

local retval = effect.handle(
  {
    [fail] = function(resume)
      return "failed"
    end,
  },
  function()
    foo()
    return "success"
  end
)

assert(retval == "failed")
