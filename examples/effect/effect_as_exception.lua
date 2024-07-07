local effect = require "neumond.effect"

local fail = effect.new("fail")

local function foo()
  fail()
end

local retval = effect.handle(
  {
    [fail] = function(resume)
      print("Caught failure.")
      -- Print stack trace where "fail" effect was performed:
      print(resume:call_only(debug.traceback))
      return "failed"
    end,
  },
  function()
    foo()
    return "success"
  end
)

assert(retval == "failed")
