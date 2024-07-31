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
local function mutex()
  -- Storing if mutex is locked:
  local locked = false
  -- Queue representing waiting tasks:
  local waiters = {}
  local waiters_rpos = 0
  local waiters_wpos = 0
  -- Function called internally to unlock mutex:
  local function unlock()
    -- Search for waiter that can be woken:
    while true do
      -- Check if there is a waiter queued:
      if waiters_wpos == waiters_rpos then
        -- There is no waiter queued.
        -- Mark mutex as unlocked:
        locked = false
        -- Finish searching for waiters:
        return
      end
      -- There is a waiter queued:
      -- Pop queued waiter:
      local waiter = waiters[waiters_rpos]
      waiters_rpos = waiters_rpos + 1
      -- Check if next waiter has already been closed:
      if not waiter.closed then
        -- Waiter has not been closed.
        -- Mark waiter as being woken up:
        waiter.waking = true
        -- Wake up waiter:
        waiter.waker()
        -- Finish searching for waiters:
        return
      end
    end
  end
  -- Guard to be returned when mutex has been locked:
  local guard = setmetatable({}, { __close = unlock })
  -- Metatable for waiter entries in queue:
  local waiter_metatbl = {
    -- Function executed when waiter is closed:
    __close = function(self)
      -- Check if this waiter is currently waking up:
      if self.waking then
        -- This waiter is currently waking up but being closed before wakeup
        -- was completed (e.g. due to canceled task).
        -- Unlock mutex again (i.e. wake next non-closed waiter, if exists, or
        -- mark mutex as unlocked if there is no non-closed waiter):
        unlock()
      else
        -- This waiter is currently not waking up.
        -- Mark waiter as closed, so it is not woken up in future either:
        self.closed = true
      end
    end,
  }
  -- Return mutex, represented as a function that locks the mutex and returns a
  -- mutex guard when called.
  return function()
    -- Check if mutex is locked:
    if locked then
      -- Mutex is locked.
      -- Create waiter with sleeper and waker:
      local sleeper, waker = notify()
      local waiter <close> = setmetatable(
        { waker = waker, waking = false },
        waiter_metatbl
      )
      -- Check if queue is full:
      local new_wpos = waiters_wpos + 1
      if new_wpos == waiters_rpos then
        -- Queue is full.
        -- Report error:
        error("overflow in mutex waiters")
      end
      -- Add waiter to FIFO queue:
      waiters[waiters_wpos] = waiter
      waiters_wpos = new_wpos
      -- Sleep with possibility to be woken:
      sleeper()
      -- waiter.waking should be set:
      --assert(waiter.waking)
      -- Mark waiter as not waking to avoid next waiter being woken:
      waiter.waking = false
    else
      -- Mutex is not locked.
      -- Mark mutex as locked:
      locked = true
    end
    -- Return mutex guard:
    return guard
  end
end
_M.mutex = mutex

-- Helper function doing nothing:
local function noop()
end

-- Methods for FIFO queues with backpressure:
local queue_methods = {}

-- Method that pushes a value into a queue:
function queue_methods:push(value)
  -- Serialize all pushes in a fair manner:
  local mutex_guard <close> = self._writer_mutex()
  -- Check if too many entries have been written or are waiting:
  local old_used = self._used
  if old_used >= self.size then
    -- Too many entries have been written or are waiting.
    -- Count pending push:
    self._used = old_used + 1
    -- Undo counting of pending push when woken or canceled:
    local writer_guard <close> = self._writer_guard
    -- Sleep with possibility to be woken:
    local sleeper, waker = notify()
    self._writer_waker = waker
    sleeper()
    self._writer_waker = noop
  end
  -- Write entry into queue:
  local old_wpos = self._buffer_wpos
  self._buffer[old_wpos] = value
  self._buffer_wpos = old_wpos + 1
  -- Count written entry:
  self._used = self._used + 1
  -- Wakeup any sleeping reader if exists:
  self._reader_waker()
end

-- Method that pops a value from a queue:
function queue_methods:pop()
  -- Serialize all pops in a fair manner:
  local mutex_guard <close> = self._reader_mutex()
  -- Wakeup any sleeping writer if exists:
  self._writer_waker()
  -- Check if no entry is available:
  local old_rpos = self._buffer_rpos
  if self._buffer_wpos == self._buffer_rpos then
    -- No entry is available.
    -- Count pending pop:
    self._used = self._used - 1
    -- Undo counting of pending pop when woken or canceled:
    local reader_guard <close> = self._reader_guard
    -- Sleep with possibility to be woken:
    local sleeper, waker = notify()
    self._reader_waker = waker
    sleeper()
    self._reader_waker = noop
  end
  -- Read value from queue:
  local value = self._buffer[old_rpos]
  self._buffer_rpos = old_rpos + 1
  -- Count read entry:
  self._used = self._used - 1
  -- Return read value:
  return value
end

-- Metatable for FIFO queues with backpressure:
local queue_metatbl = {
  __index = queue_methods,
  __len = function(self)
    return self._used
  end,
}

-- Metatable for helper guard that undoes counting a pending push:
local queue_writer_guard_metatbl = {
  __close = function(self)
    local queue = self.queue
    queue._used = queue._used - 1
  end,
}

-- Metatable for helper guard that undoes counting a pending pop:
local queue_reader_guard_metatbl = {
  __close = function(self)
    local queue = self.queue
    queue._used = queue._used + 1
  end,
}

-- Function queue(size) returns a new queue with given size:
function _M.queue(size)
  local queue = setmetatable(
    {
      _buffer = {}, -- buffered entries in queue
      _buffer_rpos = 0, -- read position in buffer
      _buffer_wpos = 0, -- write position in buffer
      _writer_waker = noop, -- wakes sleeping writer if existent
      _reader_waker = noop, -- wakes sleeping reader if existent
      _writer_mutex = mutex(), -- mutex for push method
      _reader_mutex = mutex(), -- mutex for pop method
      size = size, -- maximum number of buffered entries
      _used = 0, -- number of buffered entries plus minus pending
    },
    queue_metatbl
  )
  queue._writer_guard = setmetatable(
    {queue = queue}, queue_writer_guard_metatbl
  )
  queue._reader_guard = setmetatable(
    {queue = queue}, queue_reader_guard_metatbl
  )
  return queue
end

return _M
