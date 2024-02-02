_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"

_M.get_deregister_fd_func = effect.new("waitio.get_deregister_fd_func")
_M.get_wait_fd_read_func = effect.new("waitio.get_wait_fd_read_func")
_M.get_wait_fd_write_func = effect.new("waitio.get_wait_fd_write_func")
_M.get_catch_signal_func = effect.new("waitio.get_catch_signal_func")

function _M.deregister_fd(fd)
  return _M.get_deregister_fd_func()(fd)
end

function _M.wait_fd_read(fd)
  return _M.get_wait_fd_read_func()(fd)
end

function _M.wait_fd_write(fd)
  return _M.get_wait_fd_write_func()(fd)
end

function _M.catch_signal(sig)
  return _M.get_catch_signal_func()(sig)
end

return _M
