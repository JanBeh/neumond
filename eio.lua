_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local nbio = require "nbio"
local waitio = require "waitio"

_M.main = waitio.main

local handle_methods = {}

function handle_methods:close()
  waitio.deregister_fd(self.nbio_handle.fd)
  self.nbio_handle:close()
end

_M.handle_metatbl = {
  __close = handle_methods.close,
  __gc = handle_methods.close,
  __index = handle_methods,
}

function handle_methods:read(len)
  waitio.wait_fd_read(self.nbio_handle.fd)
  return self.nbio_handle:read(len)
end

function handle_methods:write(len)
  waitio.wait_fd_write(self.nbio_handle.fd)
  return self.nbio_handle:write(len)
end

local function wrap_handle(handle)
  return setmetatable({ nbio_handle = handle }, _M.handle_metatbl)
end

function _M.tcpconnect(...)
  local handle, err = nbio.tcpconnect(...)
  if not handle then
    return handle, err
  end
  return wrap_handle(handle)
end

local listener_methods = {}

function listener_methods:close()
  waitio.unregister_fd(self.nbio_listener.fd)
  self.nbio_listener:close()
end

_M.listener_metatbl = {
  __close = listener_methods.close,
  __gc = listener_methods.close,
  __index = listener_methods,
}

function listener_methods:accept()
  waitio.wait_fd_read(self.nbio_listener.fd)
  return wrap_handle(self.nbio_listener:accept())
end

local function wrap_listener(listener)
  return setmetatable({ nbio_listener = listener }, _M.listener_metatbl)
end

function _M.tcplisten(...)
  local listener, err = nbio.tcplisten(...)
  if not listener then
    return listener, err
  end
  return wrap_listener(listener)
end

return _M
