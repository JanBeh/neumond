_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local lkq = require "lkq"

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

local function close_timeout(self)
  if not self.elapsed then
    self:wake()
    eventqueue:remove_timeout(self.inner_handle)
  end
end

local timeout_metatbl = {
  __call = function(self)
    if self.fiber then
      error("timer is already waited for", 2)
    end
    if not self.elapsed then
      self.fiber = fiber.current()
      fiber.sleep()
      self.fiber = nil
    end
  end,
  __close = close_timeout,
  __gc = close_timeout,
  __index = {
    wake = function(self)
      self.elapsed = true
      local f = self.fiber
      if f then
        f:wake()
      end
    end,
  }
}

local function close_interval(self)
  if not self.closed then
    self.closed = true
    eventqueue:remove_interval(self.inner_handle)
  end
end

local interval_metatbl = {
  __call = function(self)
    if self.fiber then
      error("interval is already waited for", 2)
    end
    if not self.elapsed then
      self.fiber = fiber.current()
      fiber.sleep()
      self.fiber = nil
      self.elapsed = false
    end
  end,
  __close = close_interval,
  __gc = close_interval,
  __index = {
    wake = function(self)
      self.elapsed = true
      local f = self.fiber
      if f then
        f:wake()
      end
    end,
  }
}

function _M.run(...)
  local eventqueue <close> = lkq.new_queue()
  local reading_guards = {}
  local writing_guards = {}
  local pid_guards = {}
  local reading_guard_metatbl = {
    __close = function(self)
      eventqueue:remove_fd_read(self.fd)
      self.active = false
    end,
  }
  local writing_guard_metatbl = {
    __close = function(self)
      eventqueue:remove_fd_write(self.fd)
      self.active = false
    end,
  }
  local pid_guard_metatbl = {
    __close = function(self)
      pid_guards[self.pid] = nil
    end,
  }
  local function deregister_fd(fd)
    reading_guards[fd] = nil
    writing_guards[fd] = nil
    eventqueue:deregister_fd(fd)
  end
  local function wait_fd_read(fd)
    local guard = reading_guards[fd]
    if guard then
      if guard.active then
        error(
          "multiple fibers waiting for read from file descriptor " ..
          tostring(fd)
        )
      end
    else
      guard = setmetatable({fd = fd}, reading_guard_metatbl)
      reading_guards[fd] = guard
    end
    eventqueue:add_fd_read(fd, fiber.current())
    local guard <close> = guard
    guard.active = true
    fiber.sleep()
  end
  local function wait_fd_write(fd)
    local guard = writing_guards[fd]
    if guard then
      if guard.active then
        error(
          "multiple fibers waiting for write to file descriptor " ..
          tostring(fd)
        )
      end
    else
      guard = setmetatable({fd = fd}, writing_guard_metatbl)
      writing_guards[fd] = guard
    end
    eventqueue:add_fd_write(fd, fiber.current())
    local guard <close> = guard
    guard.active = true
    fiber.sleep()
  end
  local function wait_pid(pid)
    if pid_guards[pid] then
      error("multiple fibers waiting for PID " .. tostring(pid))
    end
    local guard = setmetatable({pid = pid}, pid_guard_metatbl)
    eventqueue:add_pid(pid, fiber.current())
    local guard <close> = guard
    pid_guards[pid] = guard
    fiber.sleep()
  end
  local signal_catcher_metatbl = {
    __call = function(self)
      if self.fiber then
        error("signal catcher already in use", 2)
      end
      if not self.delivered then
        self.fiber = fiber.current()
        fiber.sleep()
        self.fiber = nil
      end
      self.delivered = false
    end,
  }
  local signal_catchers = {}
  local signal_wakers = {}
  local function catch_signal(sig)
    local waker = signal_wakers[sig]
    if not signal_waker then
      signal_waker = setmetatable({}, {
        __index = {
          wake = function()
            for catcher in pairs(signal_catchers[sig]) do
              catcher.delivered = true
              local catcher_fiber = catcher.fiber
              if catcher_fiber then
                catcher_fiber:wake()
              end
            end
          end,
        },
      })
      signal_wakers[sig] = signal_waker
      eventqueue:add_signal(sig, signal_waker)
    end
    local catcher = setmetatable({delivered = false}, signal_catcher_metatbl)
    local catchers = signal_catchers[sig]
    if catchers then
      catchers[catcher] = true
    else
      catchers = setmetatable({[catcher] = true}, weak_mt)
      signal_catchers[sig] = catchers
    end
    return catcher
  end
  local function timeout(seconds)
    local outer_handle = { elapsed = false }
    outer_handle.inner_handle = eventqueue:add_timeout(seconds, outer_handle)
    return setmetatable(outer_handle, timeout_metatbl)
  end
  local function interval(seconds)
    local outer_handle = { elapsed = false, closed = false }
    outer_handle.inner_handle = eventqueue:add_interval(seconds, outer_handle)
    return setmetatable(outer_handle, interval_metatbl)
  end
  fiber.handle(
    {
      [waitio.deregister_fd] = function(resume, fd)
        return resume(effect.call, deregister_fd, fd)
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
  return fiber.main(
    _M.run,
    ...
  )
end

return _M
