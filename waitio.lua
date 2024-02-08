-- Module using effects to wait for I/O

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"

-- Effect deregister_fd(fd) deregisters file descriptor fd, which should be
-- done before closing a file descriptor that is currently being waited on:
_M.deregister_fd = effect.new("waitio.deregister_fd")

-- Effect wait_fd_read(fd) waits until file descriptor fd is ready for reading:
_M.wait_fd_read = effect.new("waitio.wait_fd_read")

-- Effect wait_fd_write(fd) waits until file descriptor fd is ready for
-- writing:
_M.wait_fd_write = effect.new("waitio.wait_fd_write")

-- Effect catch_signal(sig) starts listening for signal sig and returns a
-- callable handle which, upon calling, waits until a signal has been
-- delivered:
_M.catch_signal = effect.new("waitio.catch_signal")

return _M
