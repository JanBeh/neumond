local effect = require "neumond.effect"

local success, message = effect.pcall(function()
  error("some error", 0)
end)

assert(success == false)
message = effect.stringify_error(message)
assert(type(message) == "string")
assert(string.find(message, "^some error\r?\n"))

local error_object = setmetatable({}, {
  __tostring = function(self) return "error object" end,
})

local success, message = effect.pcall(function()
  error(error_object)
end)

assert(success == false)
message = effect.stringify_error(message)
assert(type(message) == "string")
assert(string.find(message, "^error object\r?\n"))
