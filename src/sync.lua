-- Synchronization functions

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local wait = require "neumond.wait"

-- Alias for notify effect:
local notify = wait.notify
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
      -- Repeat until a sleeper was woken:
      while true do
        -- Get waker from FIFO queue if possible:
        local waker = table.remove(wakers, 1)
        -- Break if there are no more wakers or if waking was successful:
        if not waker or waker() then
          break
        end
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
