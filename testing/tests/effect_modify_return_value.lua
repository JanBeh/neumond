local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local add = effect.new("add")
local mul = effect.new("mul")

local function foo()
  add(3)
end

local function bar()
  mul(2)
end

local retval = effect.handle(
  {
    [add] = function(resume, x)
      return resume() + x
    end,
    [mul] = function(resume, x)
      return resume() * x
    end,
  },
  function()
    foo()
    -- adding 3 happens after resuming, i.e. after the following:
    bar()
    -- multiplying by 2 happens after resuming, i.e. after the following:
    return 100
  end
)

assert(retval == 203)
