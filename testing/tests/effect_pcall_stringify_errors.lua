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
    effect.pcall_stringify_errors(function()
      checkpoint(2)
      fail()
      error("unreachable")
    end)
    error("unreachable")
  end
)

checkpoint(4)

local success, message = effect.pcall_stringify_errors(function()
  checkpoint(5)
  error("some error", 0)
end)

assert(success == false)
assert(type(message) == "string")
assert(string.find(message, "^some error\r?\n"))

checkpoint(6)

local error_object = setmetatable({}, {
  __tostring = function(self) return "error object" end,
})

local success, message = effect.pcall_stringify_errors(function()
  checkpoint(7)
  error(error_object)
end)

assert(success == false)
assert(type(message) == "string")
assert(string.find(message, "^error object\r?\n"))

checkpoint(8)
