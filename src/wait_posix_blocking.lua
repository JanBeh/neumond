-- Module for handling wait and wait_posix effects through blocking

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local effect = require "neumond.effect"
local wait = require "neumond.wait"
local wait_posix = require "neumond.wait_posix"
local lkq = require "neumond.lkq"

local function call(func, ...)
  return func(...)
end

local weak_mt = { __mode = "k" }

local function handle_call_noreset(self)
  wait.select("handle", self)
end

local function handle_call_reset(self)
  wait.select("handle", self)
  self.ready = false
end

local handle_reset_metatable = { __call = handle_call_reset }

function _M.run(...)
  local eventqueue <close> = lkq.new_queue()
  local read_fds, write_fds, pids, handles = {}, {}, {}, {}
  local poll_state_metatable = {
    __close = function(self)
      for fd in pairs(read_fds) do
        eventqueue:remove_fd_read(fd)
        read_fds[fd] = nil
      end
      for fd in pairs(write_fds) do
        eventqueue:remove_fd_write(fd)
        write_fds[fd] = nil
      end
      for pid in pairs(pids) do
        eventqueue:remove_pid(pid)
        pids[pid] = nil
      end
      for handle in pairs(handles) do
        handle._waiting = false
        handles[handle] = nil
      end
    end,
  }
  local poll_state = setmetatable({}, poll_state_metatable)
  local ready = false
  local function make_ready()
    ready = true
  end
  local function wait_select(...)
    local poll_state <close> = poll_state
    for argidx = 1, math.huge, 2 do
      local rtype, arg = select(argidx, ...)
      if rtype == nil then
        break
      end
      if rtype == "fd_read" then
        read_fds[arg] = true
        eventqueue:add_fd_read_once(arg, make_ready)
      elseif rtype == "fd_write" then
        write_fds[arg] = true
        eventqueue:add_fd_write_once(arg, make_ready)
      elseif rtype == "pid" then
        pids[arg] = true
        eventqueue:add_pid(arg, make_ready)
      elseif rtype == "handle" then
        if arg.ready then
          return
        end
        arg._waiting = true
      else
        error("unsupported resource type to wait for")
      end
    end
    ready = false
    while not ready do
      eventqueue:wait(call)
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
        function()
          for handle in pairs(handles) do
            handle.ready = true
            if handle._waiting then
              ready = true
            end
          end
        end
      )
      signal_handles[sig] = handles
    end
    local handle = setmetatable(
      { ready = false, _waiting = false },
      handle_reset_metatable
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
  local timeout_metatable = {
    __call = handle_call_noreset,
    __close = clean_timeout,
    __gc = clean_timeout,
  }
  local function timeout(seconds)
    local handle = setmetatable(
      { ready = false, _waiting = false, _inner_handle = false },
      timeout_metatable
    )
    handle.inner_handle = eventqueue:add_timeout(
      seconds,
      function()
        handle.ready = true
        if handle._waiting then
          ready = true
        end
      end
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
  local interval_metatable = {
    __call = handle_call_reset,
    __close = clean_interval,
    __gc = clean_interval,
  }
  local function interval(seconds)
    local handle = setmetatable(
      { ready = false, _waiting = false, _inner_handle = false },
      interval_metatable
    )
    handle._inner_handle = eventqueue:add_interval(
      seconds,
      function()
        handle.ready = true
        if handle._waiting then
          ready = true
        end
      end
    )
    return handle
  end
  local function notify()
    local sleeper = setmetatable(
      { ready = false, _waiting = false },
      handle_reset_metatable
    )
    local function waker()
      sleeper.ready = true
      if sleeper._waiting then
        ready = true
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
