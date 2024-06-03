-- Module for handling wait and wait_posix effects through blocking

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local effect = require "effect"
local wait = require "wait"
local wait_posix = require "wait_posix"
local lkq = require "lkq"

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

function _M.run(...)
  local eventqueue <close> = lkq.new_queue()
  local poll_state_metatbl = {
    __close = function(self)
      local entries = self.read_fds
      for fd in pairs(entries) do
        eventqueue:remove_fd_read(fd)
        entries[fd] = nil
      end
      local entries = self.write_fds
      for fd in pairs(entries) do
        eventqueue:remove_fd_write(fd)
        entries[fd] = nil
      end
      local entries = self.pids
      for pid in pairs(entries) do
        eventqueue:remove_pid(pid)
        entries[pid] = nil
      end
      local entries = self.handles
      for handle in pairs(entries) do
        handle._waiting = false
        entries[handle] = nil
      end
    end,
  }
  local poll_state = setmetatable(
    { read_fds = {}, write_fds = {}, pids = {}, handles = {} },
    poll_state_metatbl
  )
  local waiter = {
    ready = false,
    wake = function(self)
      self.ready = true
    end,
  }
  local function wait_select(...)
    local poll_state <close> = poll_state
    for argidx = 1, math.huge, 2 do
      local rtype, arg = select(argidx, ...)
      if rtype == nil then
        break
      end
      if rtype == "fd_read" then
        poll_state.read_fds[arg] = true
        eventqueue:add_fd_read_once(arg, waiter)
      elseif rtype == "fd_write" then
        poll_state.write_fds[arg] = true
        eventqueue:add_fd_write_once(arg, waiter) 
      elseif rtype == "pid" then
        poll_state.pids[arg] = true
        eventqueue:add_pid(arg, waiter)
      elseif rtype == "handle" then
        if arg.ready then
          return
        end
        arg._waiting = true
      else
        error("unsupported resource type to wait for")
      end
    end
    waiter.ready = false
    while not waiter.ready do
      eventqueue:wait(wake)
    end
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
            for handle, waker in pairs(handles) do
              waker()
            end
          end,
        }
      )
      signal_handles[sig] = handles
    end
    local handle = setmetatable(
      { ready = false, _waiting = false },
      handle_reset_metatbl
    )
    handles[handle] = function()
      handle.ready = true
      if handle._waiting then
        waiter.ready = true
      end
    end
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
      { ready = false, _waiting = false, _inner_handle = false },
      timeout_metatbl
    )
    handle.inner_handle = eventqueue:add_timeout(
      seconds,
      {
        wake = function()
          handle.ready = true
          if handle._waiting then
            waiter.ready = true
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
    __close = clean_interval,
    __gc = clean_interval,
  }
  local function interval(seconds)
    local handle = setmetatable(
      { ready = false, _waiting = false, _inner_handle = false },
      interval_metatbl
    )
    handle._inner_handle = eventqueue:add_interval(
      seconds,
      {
        wake = function()
          handle.ready = true
          if handle._waiting then
            waiter.ready = true
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
      if sleeper._waiting then
        waiter.ready = true
      end
    end
    return sleeper, waker
  end
  return effect.handle(
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
        return resume()
      end,
      [wait_posix.catch_signal] = function(resume, sig)
        return resume:call(catch_signal, sig)
      end,
    },
    ...
  )
end

_M.main = _M.run

return _M
