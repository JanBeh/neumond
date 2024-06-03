-- Platform independent waiting and synchronization

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local effect = require "effect"

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

-- Effect timeout(seconds) starts an interval timer and returns a
-- (to-be-closed) handle that waits, when called, until the next tick of the
-- interval:
_M.interval = effect.new("wait.interval")

-- Effect notify() returns a sleeper (as first return value) and a waker (as
-- second return value) where the sleeper, when called, will wait until the
-- waker has been called:
local notify = effect.new("wait.notify")
_M.notify = notify

-- Function mutex() creates a mutex handle that, when called, waits until the
-- mutex can be locked and returns a to-be-closed lock guard:
function _M.mutex()
  -- State of mutex (locked or unlocked):
  local locked = false
  -- FIFO queue of waker handles:
  local wakers = {}
  -- Mutex guard to be returned when mutex was locked:
  local guard = setmetatable({}, {
    -- Function to be executed when mutex guard is closed:
    __close = function()
      -- Set mutex state to unlocked:
      locked = false
      -- Get waker from FIFO queue if possible:
      local waker = table.remove(wakers, 1)
      if waker then
        -- Waker was obtained.
        -- Trigger waker:
        waker()
      end
    end,
  })
  -- Return mutex handle (implemented as a function):
  return function()
    -- Check if mutex is locked:
    if locked then
      -- Mutex is locked.
      -- Create new waker and waiter pair:
      local sleeper, waker = notify()
      -- Store waker in FIFO queue:
      wakers[#wakers+1] = waker
      -- Wait for wakeup:
      sleeper()
    end
    -- Set mutex state to locked:
    locked = true
    -- Return mutex guard, which will unlock the mutex when closed:
    return guard
  end
end

return _M
