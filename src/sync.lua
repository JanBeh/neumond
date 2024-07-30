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
  -- State of mutex (locked or unlocked):
  local locked = false
  -- FIFO queue of waker handles:
  local wakers = {}
  -- Mutex guard to be returned when mutex was locked:
  local guard = setmetatable({}, {
    -- Function to be executed when mutex guard is closed:
    __close = function()
      -- Repeat until a sleeper was woken or until there are no more sleepers:
      while true do
        -- Get waker from FIFO queue if possible:
        local waker = table.remove(wakers, 1)
        -- Check if there are no more wakers:
        if not waker then
          -- There are no more wakers.
          -- Set mutex state to unlocked:
          locked = false
          -- Break loop:
          break
        end
        -- Break if waking was successful:
        if waker() then
          -- TODO: If woken task gets killed, mutex will be locked forever.
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
    else
      -- Set mutex state to locked:
      locked = true
    end
    -- Return mutex guard, which will unlock the mutex when closed:
    return guard
  end
end
_M.mutex = mutex

local function noop()
end

local queue_methods = {}

function queue_methods:push(value)
  local mutex_guard <close> = self._writer_mutex()
  local old_used = self._used
  if old_used >= self.size then
    self._used = old_used + 1
    local writer_guard <close> = self._writer_guard
    local sleeper, waker = notify()
    self._writer_waker = waker
    sleeper()
    self._writer_waker = noop
  end
  local old_wpos = self._buffer_wpos
  self._buffer[old_wpos] = value
  self._buffer_wpos = old_wpos + 1
  self._used = self._used + 1
  self._reader_waker()
end

function queue_methods:pop()
  local mutex_guard <close> = self._reader_mutex()
  self._writer_waker()
  local old_rpos = self._buffer_rpos
  if self._buffer_wpos == self._buffer_rpos then
    self._used = self._used - 1
    local reader_guard <close> = self._reader_guard
    local sleeper, waker = notify()
    self._reader_waker = waker
    sleeper()
    self._reader_waker = noop
  end
  local value = self._buffer[old_rpos]
  self._buffer_rpos = old_rpos + 1
  self._used = self._used - 1
  return value
end

local queue_metatbl = {
  __index = function(self, key)
    return queue_methods[key]
  end,
}

local queue_writer_guard_metatbl = {
  __close = function(self)
    local queue = self.queue
    queue._used = queue._used - 1
  end,
}

local queue_reader_guard_metatbl = {
  __close = function(self)
    local queue = self.queue
    queue._used = queue._used + 1
  end,
}

function _M.queue(size)
  local queue = setmetatable(
    {
      _buffer = {},
      _buffer_rpos = 0,
      _buffer_wpos = 0,
      _writer_waker = noop,
      _reader_waker = noop,
      _writer_mutex = mutex(),
      _reader_mutex = mutex(),
      size = size,
      _used = 0,
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
