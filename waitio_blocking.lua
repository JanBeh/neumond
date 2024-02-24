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
  local function close_timeout(self)
    waiters[self] = nil
    eventqueue:remove_timeout(self.inner_handle)
  end
  local timeout_metatbl = {
    __call = function(self)
      while waiters[self] do
        eventqueue:wait(wake)
      end
    end,
    __close = close_timeout,
    __gc = close_timeout,
  }
  local function close_interval(self)
    eventqueue:remove_timeout(self.inner_handle)
  end
  local interval_metatbl = {
    __call = function(self)
      while waiters[self] do
        eventqueue:wait(wake)
      end
      waiters[self] = true
    end,
    __close = close_interval,
    __gc = close_interval,
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
        local instance = { waiting = true }
        local waiter = signal_waiters[sig]
        local instances
        if waiter then
          instances = waiter.instances
          if not waiters[waiter] then
            for instance in pairs(instances) do
              instance.waiting = false
            end
            waiters[waiter] = true
          end
          instances[instance] = true
        else
          instances = setmetatable({[instance] = true}, weak_mt)
          waiter = { instances = instances }
          signal_waiters[sig] = waiter
          eventqueue:add_signal(sig, waiter)
          waiters[waiter] = true
        end
        return resume(function()
          while instance.waiting do
            eventqueue:wait(wake)
            if not waiters[waiter] then
              for instance in pairs(instances) do
                instance.waiting = false
              end
              waiters[waiter] = true
            end
          end
        end)
      end,
      [waitio.timeout] = function(resume, seconds)
        local waiter = {}
        waiter.inner_handle = eventqueue:add_timeout(seconds, waiter)
        setmetatable(waiter, timeout_metatbl)
        waiters[waiter] = true
        return resume(waiter)
      end,
      [waitio.interval] = function(resume, seconds)
        local waiter = {}
        waiter.inner_handle = eventqueue:add_interval(seconds, waiter)
        setmetatable(waiter, interval_metatbl)
        waiters[waiter] = true
        return resume(waiter)
      end,
    },
    ...
  )
end

_M.main = _M.run

return _M
