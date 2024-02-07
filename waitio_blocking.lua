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
  local waiters = {}
  local function wake(waiter)
    waiters[waiter] = nil
  end
  local signal_catchers = {}
  local function deregister_fd(fd)
    eventqueue:deregister_fd(fd)
  end
  local function wait_fd_read(fd)
    local waiter = {}
    waiters[waiter] = true
    eventqueue:add_fd_read_once(fd, waiter)
    while waiters[waiter] do
      eventqueue:wait(wake)
    end
  end
  local function wait_fd_write(fd)
    local waiter = {}
    waiters[waiter] = true
    eventqueue:add_fd_write_once(fd, waiter)
    while waiters[waiter] do
      eventqueue:wait(wake)
    end
  end
  local function catch_signal(sig)
    local waiter = signal_waiters[sig]
    if not waiter then
      waiter = {}
      signal_waiters[sig] = waiter
      waiters[waiter] = true
    end
    eventqueue:add_signal(sig, waiter)
    return function()
      while waiters[waiter] do
        eventqueue:wait(wake)
      end
      waiters[waiter] = true
    end
  end
  effect.handle(
    {
      [waitio.get_deregister_fd_func] = function(resume)
        return resume(deregister_fd)
      end,
      [waitio.get_wait_fd_read_func] = function(resume)
        return resume(wait_fd_read)
      end,
      [waitio.get_wait_fd_write_func] = function(resume)
        return resume(wait_fd_write)
      end,
      [waitio.get_catch_signal_func] = function(resume)
        return resume(catch_signal)
      end,
    },
    ...
  )
end

_M.main = _M.run

return _M
