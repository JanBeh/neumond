-- Module using effects to wait for I/O

-- NOTE: Effects in this module do not operate directly but return a function
-- that has to be called to actually perform the desired effect. This allows
-- execution in the context of the caller rather than the effect handler.


-- Module preamble and required modules:

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"


-- Effects to be handled by a main loop:

-- Effect returning a function that deregisters a file descriptor (passed as
-- argument to the returned function) which should be done before closing a
-- file descriptor that is currently being waited on:
_M.get_deregister_fd_func = effect.new("waitio.get_deregister_fd_func")

-- Effect returning a function that waits for a file descriptor (passed as
-- argument to the returned function) to be ready for reading:
_M.get_wait_fd_read_func = effect.new("waitio.get_wait_fd_read_func")

-- Effect returning a function that waits for a file descriptor (passed as
-- argument to the returned function) to be ready for writing:
_M.get_wait_fd_write_func = effect.new("waitio.get_wait_fd_write_func")

-- Effect returning a function that starts listening for a signal (passed as
-- argument to the function returned by the effect) and returns a callable
-- handle, which, upon calling, waits until a signal has been delivered
-- since the handle has been created:
_M.get_catch_signal_func = effect.new("waitio.get_catch_signal_func")


-- Functions that can be used to wait for I/O if the above effect handlers are
-- handled by the current context:

-- Function that deregisters a file descriptor (passed as argument) which
-- should be done before closing a file descriptor that is currently being
-- waited on:
function _M.deregister_fd(fd)
  return _M.get_deregister_fd_func()(fd)
end

-- Function that waits for a file descriptor (passed as argument) to be ready
-- for reading:
function _M.wait_fd_read(fd)
  return _M.get_wait_fd_read_func()(fd)
end

-- Function that waits for a file descriptor (passed as argument) to be ready
-- for writing:
function _M.wait_fd_write(fd)
  return _M.get_wait_fd_write_func()(fd)
end

-- Function that starts listening for a signal (passed as argument) and returns
-- a callable handle, which, upon calling, waits until a signal has been
-- delivered since the handle has been created:
function _M.catch_signal(sig)
  return _M.get_catch_signal_func()(sig)
end


return _M
