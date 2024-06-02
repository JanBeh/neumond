-- Module providing an abstract yield effect

-- Import "effect" module:
local effect = require "effect"

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- The module table is used as effect:
local _M = setmetatable({}, {
  __call = effect.perform,
  __tostring = function() return "yield effect" end,
})

-- Install default handler that is a no-op:
effect.default_handlers[_M] = function() end

return _M
