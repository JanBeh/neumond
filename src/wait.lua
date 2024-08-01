-- Platform independent waiting and basic synchronization

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local effect = require "neumond.effect"

-- Effect select(...) waits until one of several listed events occurred. Each
-- event is denoted by two arguments, i.e. the number of arguments passed to
-- the select effect must be a multiple of two. This module only defines the
-- following arguments:
--   * "handle" followed by a handle that is tested for the "ready" attribute
--     (which is not reset)
-- But in a POSIX environment (see wait_posix module), other modules are
-- expected to additionally support:
--   * "fd_read" followed by an integer file descriptor
--   * "fd_write" followed by an integer file descriptor
--   * "pid" followed by an integer process ID
_M.select = effect.new("wait.select")

-- Effect timeout(seconds) starts a one-shot timer and returns a (to-be-closed)
-- handle that waits, when called, until the timer has elapsed:
_M.timeout = effect.new("wait.timeout")

-- Effect interval(seconds) starts an interval timer and returns a
-- (to-be-closed) handle that waits, when called, until the next tick of the
-- interval:
_M.interval = effect.new("wait.interval")

-- Effect notify() returns a sleeper (as first return value) and a waker (as
-- second return value) where the sleeper, when called, will wait until the
-- waker has been called:
local notify = effect.new("wait.notify")
_M.notify = notify

return _M
