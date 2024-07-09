local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local fail = effect.new("fail")

effect.handle(
  {
    [fail] = function(resume)
      checkpoint(3)
    end,
  },
  function()
    checkpoint(1)
    effect.auto_traceback(function()
      checkpoint(2)
      fail()
      error("unreachable")
    end)
    error("unreachable")
  end
)

checkpoint(4)

local success, message = pcall(function()
  checkpoint(5)
  effect.auto_traceback(function()
    checkpoint(6)
    error("some error", 0)
  end)
  error("unreachable")
end)

assert(success == false)
assert(type(message) == "string")
assert(string.find(message, "^some error\r?\n"))

checkpoint(7)

local error_object = setmetatable({}, {
  __tostring = function(self) return "error object" end,
})

local success, message = effect.pcall(function()
  checkpoint(8)
  effect.auto_traceback(function()
    checkpoint(9)
    error(error_object)
  end)
  error("unreachable")
end)

assert(success == false)
assert(type(message) == "string")
assert(string.find(message, "^error object\r?\n"))

checkpoint(10)
