-- Runtime for POSIX platforms supporting fibers and async I/O

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

local effect = require "neumond.effect"
local wait_posix_fiber = require "neumond.wait_posix_fiber"

return function(...)
  effect.stringify_errors(wait_posix_fiber.main, ...)
end
