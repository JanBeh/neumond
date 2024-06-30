-- Module using effects to wait for I/O on POSIX platforms

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local effect = require "neumond.effect"
local wait = require "neumond.wait"

-- Effect deregister_fd(fd) deregisters file descriptor fd, which should be
-- done before closing a file descriptor that is currently waited on:
_M.deregister_fd = effect.new("wait_posix.deregister_fd")

-- wait_fd_read(fd) waits until file descriptor fd is ready for reading:
function _M.wait_fd_read(fd)
  return wait.select("fd_read", fd)
end

-- wait_fd_write(fd) waits until file descriptor fd is ready for writing:
function _M.wait_fd_write(fd)
  return wait.select("fd_write", fd)
end

-- wait_pid(pid) waits until the process with the given pid has exited:
function _M.wait_pid(pid)
  return wait.select("pid", pid)
end

-- Effect catch_signal(sig) starts listening for signal sig and returns a
-- callable handle which, upon calling, waits until a signal has been
-- delivered:
_M.catch_signal = effect.new("wait_posix.catch_signal")

return _M
