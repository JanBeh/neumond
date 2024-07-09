local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local fail = effect.new("fail")

local success, message = effect.pcall(function()
  effect.handle(
    {
      [fail] = function(resume)
        checkpoint(3)
      end,
    },
    function()
      checkpoint(1)
      effect.pcall(function()
        checkpoint(2)
        fail()
        error("unreachable")
      end)
      error("unreachable")
    end
  )
  checkpoint(4)
  error("some error", 0)
end)

assert(success == false)
assert(type(message) == "string")
assert(string.find(message, "^some error\r?\n"))

checkpoint(5)

local error_object = setmetatable({}, {
  __tostring = function(self) return "error object" end,
})

local success, message = effect.pcall(function()
  checkpoint(6)
  error(error_object)
end)

assert(success == false)
assert(message == error_object)

checkpoint(7)
