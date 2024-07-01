-- Module for handling wait and wait_posix effects by sleeping (i.e. yielding
-- to other fibers)

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local wait_posix = require "neumond.wait_posix"
local lkq = require "neumond.lkq"

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

local function handle_call_noreset(self)
  wait.select("handle", self)
end

local function handle_call_reset(self)
  wait.select("handle", self)
  self.ready = false
end

local handle_reset_metatbl = {
  __call = handle_call_reset,
}

local function run(...)
  local eventqueue <close> = lkq.new_queue()
  local read_fd_locks, write_fd_locks, pid_locks, handle_locks = {}, {}, {}, {}
  local function deregister_fd(fd)
    eventqueue:deregister_fd(fd)
    local fib = read_fd_locks[fd]
    if fib then
      read_fd_locks[fd] = nil
      fib:wake()
    end
    local fib = write_fd_locks[fd]
    if fib then
      write_fd_locks[fd] = nil
      fib:wake()
    end
  end
  local poll_state_metatbl = {
    __close = function(self)
      local entries = self.read_fds
      for fd in pairs(entries) do
        if read_fd_locks[fd] then
          eventqueue:remove_fd_read(fd)
        end
        read_fd_locks[fd] = nil
        entries[fd] = nil
      end
      local entries = self.write_fds
      for fd in pairs(entries) do
        if write_fd_locks[fd] then
          eventqueue:remove_fd_write(fd)
        end
        write_fd_locks[fd] = nil
        entries[fd] = nil
      end
      local entries = self.pids
      for pid in pairs(entries) do
        eventqueue:remove_pid(pid)
        pid_locks[pid] = nil
        entries[pid] = nil
      end
      local entries = self.handles
      for handle in pairs(entries) do
        handle._fiber = false
        handle_locks[handle] = nil
        entries[handle] = nil
      end
    end,
  }
  local fiber_poll_states = setmetatable({}, weak_mt)
  local function wait_select(...)
    local current_fiber = fiber.current()
    local poll_state = fiber_poll_states[current_fiber]
    if not poll_state then
      poll_state = setmetatable(
        { read_fds = {}, write_fds = {}, pids = {}, handles = {} },
        poll_state_metatbl
      )
      fiber_poll_states[current_fiber] = poll_state
    end
    local poll_state <close> = poll_state
    for argidx = 1, math.huge, 2 do
      local rtype, arg = select(argidx, ...)
      if rtype == nil then
        break
      end
      if rtype == "fd_read" then
        if read_fd_locks[arg] then
          error(
            "multiple fibers wait for reading from file descriptor " ..
            tostring(arg)
          )
        end
        poll_state.read_fds[arg] = true
        read_fd_locks[arg] = current_fiber
        eventqueue:add_fd_read_once(arg, current_fiber)
      elseif rtype == "fd_write" then
        if write_fd_locks[arg] then
          error(
            "multiple fibers wait for writing to file descriptor " ..
            tostring(arg)
          )
        end
        poll_state.write_fds[arg] = true
        write_fd_locks[arg] = current_fiber
        eventqueue:add_fd_write_once(arg, current_fiber)
      elseif rtype == "pid" then
        if pid_locks[arg] then
          error(
            "multiple fibers wait for process with PID " .. tostring(arg)
          )
        end
        poll_state.pids[arg] = true
        pid_locks[arg] = true
        eventqueue:add_pid(arg, current_fiber)
      elseif rtype == "handle" then
        if arg.ready then
          return
        end
        if handle_locks[arg] then
          error("multiple fibers wait for handle " .. tostring(arg))
        end
        poll_state.handles[arg] = true
        handle_locks[arg] = true
        arg._fiber = current_fiber
      else
        error("unsupported resource type to wait for")
      end
    end
    fiber.sleep()
  end
  local signal_handles = {}
  local function catch_signal(sig)
    local handles = signal_handles[sig]
    if not handles then
      handles = setmetatable({}, weak_mt)
      signal_handles[sig] = false
      eventqueue:add_signal(
        sig,
        {
          wake = function()
            for handle in pairs(handles) do
              handle.ready = true
              local fib = handle._fiber
              if fib then
                fib:wake()
              end
            end
          end,
        }
      )
      signal_handles[sig] = handles
    end
    local handle = setmetatable(
      { ready = false, _fiber = false },
      handle_reset_metatbl
    )
    handles[handle] = true
    return handle
  end
  local function clean_timeout(self)
    local inner_handle = self._inner_handle
    self._inner_handle = nil
    if inner_handle then
      eventqueue:remove_timeout(seconds, inner_handle)
    end
  end
  local timeout_metatbl = {
    __call = handle_call_noreset,
    __close = clean_timeout,
    __gc = clean_timeout,
  }
  local function timeout(seconds)
    local handle = setmetatable(
      { ready = false, _fiber = false, _inner_handle = false },
      timeout_metatbl
    )
    handle._inner_handle = eventqueue:add_timeout(
      seconds,
      {
        wake = function()
          handle.ready = true
          local fib = handle._fiber
          if fib then
            fib:wake()
          end
        end,
      }
    )
    return handle
  end
  local function clean_interval(self)
    local inner_handle = self._inner_handle
    self._inner_handle = nil
    if inner_handle then
      eventqueue:remove_interval(seconds, inner_handle)
    end
  end
  local interval_metatbl = {
    __call = handle_call_reset,
    __newindex = handle_newindex,
    __close = clean_interval,
    __gc = clean_interval,
  }
  local function interval(seconds)
    local handle = setmetatable(
      { ready = false, _fiber = false, _inner_handle = false },
      interval_metatbl
    )
    handle._inner_handle = eventqueue:add_interval(
      seconds,
      {
        wake = function()
          handle.ready = true
          local fib = handle._fiber
          if fib then
            fib:wake()
          end
        end,
      }
    )
    return handle
  end
  local function notify()
    local sleeper = setmetatable(
      { ready = false, _waiting = false },
      handle_reset_metatbl
    )
    local function waker()
      sleeper.ready = true
      local fib = sleeper._fiber
      if fib then
        fib:wake()
      end
    end
    return sleeper, waker
  end
  return fiber.handle(
    {
      [wait.select] = function(resume, ...)
        return resume:call(wait_select, ...)
      end,
      [wait.timeout] = function(resume, seconds)
        return resume:call(timeout, seconds)
      end,
      [wait.interval] = function(resume, seconds)
        return resume:call(interval, seconds)
      end,
      [wait.notify] = function(resume)
        return resume:call(notify)
      end,
      [wait_posix.deregister_fd] = function(resume, ...)
        return resume:call(deregister_fd, ...)
      end,
      [wait_posix.catch_signal] = function(resume, sig)
        return resume:call(catch_signal, sig)
      end,
    },
    function(body, ...)
      fiber.spawn(function()
        while true do
          if fiber.pending() then
            eventqueue:poll(wake)
          else
            eventqueue:wait(wake)
          end
          fiber.yield()
        end
      end)
      return body(...)
    end,
    ...
  )
end

function _M.main(...)
  return fiber.scope(run, ...)
end

return _M
