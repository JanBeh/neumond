local effect = require "neumond.effect"

local fail = effect.new("fail")

local retval = effect.handle(
  {
    [fail] = function(resume)
      return "failed"
    end,
  },
  function()
    fail()
    return "success"
  end
)

assert(retval == "failed")
