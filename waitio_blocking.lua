_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local waitio = require "waitio"
local lkq = require "lkq"

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

local handle_reset_metatbl = {
  __call = function(self)
    waitio.select("handle", self)
    self.ready = false
  end,
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
        handle.waiting = false
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
        arg.waiting = true
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
            for handle in pairs(handles) do
              handle.ready = true
              if handle.waiting then
                waiter.ready = true
              end
            end
          end,
        }
      )
      signal_handles[sig] = handles
    end
    local handle = setmetatable(
      { ready = false, waiting = false },
      handle_reset_metatbl
    )
    handles[handle] = true
    return handle
  end
  local function clean_timeout(self)
    local inner_handle = self.inner_handle
    self.inner_handle = nil
    if inner_handle then
      eventqueue:remove_timeout(seconds, inner_handle)
    end
  end
  local timeout_metatbl = {
    __call = function(self) waitio.select("handle", self) end,
    __close = clean_timeout,
    __gc = clean_timeout,
  }
  local function timeout(seconds)
    local handle = setmetatable(
      { ready = false, waiting = false, inner_handle = false },
      timeout_metatbl
    )
    handle.inner_handle = eventqueue:add_timeout(
      seconds,
      {
        wake = function()
          handle.ready = true
          if handle.waiting then
            waiter.ready = true
          end
        end,
      }
    )
    return handle
  end
  local function clean_interval(self)
    local inner_handle = self.inner_handle
    self.inner_handle = nil
    if inner_handle then
      eventqueue:remove_interval(seconds, inner_handle)
    end
  end
  local interval_metatbl = {
    __call = function(self)
      waitio.select("handle", self)
      self.ready = false
    end,
    __close = clean_interval,
    __gc = clean_interval,
  }
  local function interval(seconds)
    local handle = setmetatable(
      { ready = false, waiting = false, inner_handle = false },
      interval_metatbl
    )
    handle.inner_handle = eventqueue:add_interval(
      seconds,
      {
        wake = function()
          handle.ready = true
          if handle.waiting then
            waiter.ready = true
          end
        end,
      }
    )
    return handle
  end
  return effect.handle(
    {
      [waitio.select] = function(resume, ...)
        return resume(effect.call, wait_select, ...)
      end,
      [waitio.wait_fd_read] = function(resume, fd)
        return resume(effect.call, wait_fd_read, fd)
      end,
      [waitio.wait_fd_write] = function(resume, fd)
        return resume(effect.call, wait_fd_write, fd)
      end,
      [waitio.wait_pid] = function(resume, pid)
        return resume(effect.call, wait_pid, pid)
      end,
      [waitio.catch_signal] = function(resume, sig)
        return resume(effect.call, catch_signal, sig)
      end,
      [waitio.timeout] = function(resume, seconds)
        return resume(effect.call, timeout, seconds)
      end,
      [waitio.interval] = function(resume, seconds)
        return resume(effect.call, interval, seconds)
      end,
    },
    ...
  )
end

_M.main = _M.run

return _M
