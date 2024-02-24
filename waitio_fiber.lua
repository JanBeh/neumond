_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local lkq = require "lkq"

local waker_metatbl = {
  __index = {
    wake = function(self)
      self.woken = true
      self.fiber:wake()
    end,
  },
}

local catcher_metatbl = {
  __call = function(self)
    while not self.triggered do
      if self.fiber then
        error("catcher already in use", 2)
      end
      self.fiber = fiber.current()
      fiber.sleep()
      self.fiber = nil
    end
    self.triggered = false
  end,
}

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

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
  local signal_catchers = {}
  local signal_fibers <close> = setmetatable({}, {
    __close = function(self)
      for sig, signal_fiber in pairs(self) do
        signal_fiber:kill()
      end
    end,
  })
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
    local waker = setmetatable({fiber = fiber.current()}, waker_metatbl)
    eventqueue:add_pid(pid, waker)
    local guard <close> = guard
    pid_guards[pid] = guard
    while not waker.woken do
      fiber.sleep()
    end
  end
  local function catch_signal(sig)
    local signal_fiber = signal_fibers[sig]
    if not signal_fiber then
      local parent = fiber.current()
      signal_fiber = fiber.spawn(function()
        parent:wake()
        while true do
          fiber.sleep()
          for catcher in pairs(signal_catchers[sig]) do
            catcher.triggered = true
            local catcher_fiber = catcher.fiber
            if catcher_fiber then
              catcher_fiber:wake()
            end
          end
        end
      end)
      signal_fibers[sig] = signal_fiber
      fiber.sleep()
      eventqueue:add_signal(sig, signal_fiber)
    end
    local catcher = setmetatable({triggered = false}, catcher_metatbl)
    local catchers = signal_catchers[sig]
    if catchers then
      catchers[catcher] = true
    else
      catchers = setmetatable({[catcher] = true}, weak_mt)
      signal_catchers[sig] = catchers
    end
    return catcher
  end
  -- TODO: support waiting for timers/intervals in multiple fibers?
  local timer_waiting = setmetatable({}, weak_mt)
  local timer_handles = setmetatable({}, weak_mt)
  local timer_fiber = setmetatable({}, weak_mt)
  local timeout_metatbl = {
    __call = function(self)
      local current_fiber = fiber.current()
      while timer_waiting[self] do
        timer_fiber[self] = current_fiber
        fiber.sleep()
      end
    end,
    __close = function(self)
      if timer_waiting[self] then
        local f = timer_fiber[self]
        if f then
          f:wake()
        end
        timer_waiting[self] = nil
        eventqueue:remove_timeout(timer_handles[self])
      end
    end,
    __index = {
      wake = function(self)
        timer_fiber[self]:wake()
        timer_waiting[self] = nil
      end,
    }
  }
  local function clear_interval(outer_handle)
    local inner_handle = timer_handles[outer_handle]
    if inner_handle then
      eventqueue:remove_timeout(inner_handle)
      timer_handles[outer_handle] = nil
    end
  end
  local interval_metatbl = {
    __call = function(self)
      local current_fiber = fiber.current()
      while timer_waiting[self] do
        timer_fiber[self] = current_fiber
        fiber.sleep()
      end
      timer_waiting[self] = true
    end,
    __close = clear_interval,
    __gc = clear_interval,
    __index = {
      wake = function(self)
        timer_fiber[self]:wake()
        timer_waiting[self] = nil
      end,
    }
  }
  local function timeout(seconds)
    local outer_handle = setmetatable({}, timeout_metatbl)
    local inner_handle = eventqueue:add_timeout(seconds, outer_handle)
    timer_handles[outer_handle] = inner_handle
    timer_waiting[outer_handle] = true
    return outer_handle
  end
  local function interval(seconds)
    local outer_handle = setmetatable({}, interval_metatbl)
    local inner_handle = eventqueue:add_interval(seconds, outer_handle)
    timer_handles[outer_handle] = inner_handle
    timer_waiting[outer_handle] = true
    return outer_handle
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
