-- Handling of waitio effects in a blocking fashion without fibers

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local waitio = require "waitio"
local lkq = require "lkq"

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

function _M.run(...)
  local eventqueue <close> = lkq.new_queue()
  local signal_waiters = {}
  local waiters = setmetatable({}, weak_mt)
  local function wake(waiter)
    waiters[waiter] = nil
  end
  local timer_handles = setmetatable({}, weak_mt)
  local timeout_metatbl = {
    __call = function(self)
      while waiters[self] do
        eventqueue:wait(wake)
      end
    end,
    __close = function(self)
      if waiters[self] then
        waiters[self] = nil
        eventqueue:remove_timeout(timer_handles[self])
      end
    end,
  }
  local function clear_interval(waiter)
    local handle = timer_handles[waiter]
    if handle then
      eventqueue:remove_timeout(handle)
      timer_handles[waiter] = nil
    end
  end
  local interval_metatbl = {
    __call = function(self)
      while waiters[self] do
        eventqueue:wait(wake)
      end
      waiters[self] = true
    end,
    __close = clear_interval,
    __gc = clear_interval,
  }
  effect.handle(
    {
      [waitio.deregister_fd] = function(resume, fd)
        eventqueue:deregister_fd(fd)
        return resume()
      end,
      [waitio.wait_fd_read] = function(resume, fd)
        local waiter = {}
        eventqueue:add_fd_read_once(fd, waiter)
        waiters[waiter] = true
        while waiters[waiter] do
          eventqueue:wait(wake)
        end
        return resume()
      end,
      [waitio.wait_fd_write] = function(resume, fd)
        local waiter = {}
        eventqueue:add_fd_write_once(fd, waiter)
        waiters[waiter] = true
        while waiters[waiter] do
          eventqueue:wait(wake)
        end
        return resume()
      end,
      [waitio.wait_pid] = function(resume, pid)
        local waiter = {}
        eventqueue:add_pid(pid, waiter)
        waiters[waiter] = true
        while waiters[waiter] do
          eventqueue:wait(wake)
        end
        return resume()
      end,
      [waitio.catch_signal] = function(resume, sig)
        local waiter = signal_waiters[sig]
        if not waiter then
          waiter = {}
          signal_waiters[sig] = waiter
          eventqueue:add_signal(sig, waiter)
          waiters[waiter] = true
        end
        return resume(function()
          while waiters[waiter] do
            eventqueue:wait(wake)
          end
          waiters[waiter] = true
        end)
      end,
      [waitio.timeout] = function(resume, seconds)
        local waiter = setmetatable({}, timeout_metatbl)
        local handle = eventqueue:add_timeout(seconds, waiter)
        timer_handles[waiter] = handle
        waiters[waiter] = true
        return resume(waiter)
      end,
      [waitio.interval] = function(resume, seconds)
        local waiter = setmetatable({}, interval_metatbl)
        local handle = eventqueue:add_interval(seconds, waiter)
        timer_handles[waiter] = handle
        waiters[waiter] = true
        return resume(waiter)
      end,
    },
    ...
  )
end

_M.main = _M.run

return _M
