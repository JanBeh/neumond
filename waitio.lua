-- Module using effects to wait for I/O

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"

-- Effect deregister_fd(fd) deregisters file descriptor fd, which should be
-- done before closing a file descriptor that is currently waited on:
_M.deregister_fd = effect.new("waitio.deregister_fd")

-- Effect select(...) waits until one of several listed events occurred. Each
-- event is denoted by two arguments, i.e. the number of arguments passed to
-- the select effect should be a multiple of two. The following arguments are
-- permitted:
--   * "fd_read",  file_descriptor
--   * "fd_write", file_descriptor
--   * "pid",      pid
--   * "handle",   handle (tested for "ready" attribute, which is not reset)
_M.select = effect.new("waitio.select")

-- wait_fd_read(fd) waits until file descriptor fd is ready for reading:
function _M.wait_fd_read(fd)
  return _M.select("fd_read", fd)
end

-- wait_fd_write(fd) waits until file descriptor fd is ready for writing:
function _M.wait_fd_write(fd)
  return _M.select("fd_write", fd)
end

-- wait_pid(pid) waits until the process with the given pid has exited:
function _M.wait_pid(pid)
  return _M.select("pid", pid)
end

-- Effect catch_signal(sig) starts listening for signal sig and returns a
-- callable handle which, upon calling, waits until a signal has been
-- delivered:
_M.catch_signal = effect.new("waitio.catch_signal")

-- Effect timeout(seconds) starts a one-shot timer and returns a (to-be-closed)
-- handle that waits, when called, until the timer has elapsed:
_M.timeout = effect.new("waitio.timeout")

-- Effect timeout(seconds) starts an interval timer and returns a
-- (to-be-closed) handle that waits, when called, until the next tick of the
-- interval:
_M.interval = effect.new("waitio.interval")

return _M
