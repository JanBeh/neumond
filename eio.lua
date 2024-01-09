_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local nbio = require "nbio"
local waitio = require "waitio"

local chunksize = 1024

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

function handle_methods:read_unbuffered(maxlen)
  if len == 0 then
    return ""
  end
  local result, errmsg = self.nbio_handle:read_unbuffered(maxlen)
  if result == "" then
    waitio.wait_fd_read(self.nbio_handle.fd)
    return self.nbio_handle:read_unbuffered(maxlen)
  end
  if result then
    return result
  else
    return result, errmsg
  end
end

function handle_methods:read(maxlen, terminator)
  if len == 0 then
    return ""
  end
  while true do
    local result, errmsg = self.nbio_handle:read(maxlen, terminator)
    if not result then
      return result, errmsg
    end
    if result ~= "" then
      return result
    end
    waitio.wait_fd_read(self.nbio_handle.fd)
  end
end

function handle_methods:write_unbuffered(...)
  local result, errmsg = self.nbio_handle:write_unbuffered(...)
  if result == 0 then
    waitio.wait_fd_write(self.nbio_handle.fd)
    return self.nbio_handle:write_unbuffered(...)
  end
  if result then
    return result
  else
    return result, errmsg
  end
end

function handle_methods:write(data)
  local start = 1
  local total = #data
  while start <= total do
    local result, errmsg = self.nbio_handle:write(data, start)
    if result then
      start = start + result
    else
      return result, errmsg
    end
    waitio.wait_fd_write(self.nbio_handle.fd)
  end
end

function handle_methods:flush()
  while true do
    local result, errmsg = self.nbio_handle:flush()
    if result == 0 then
      break
    elseif not result then
      return result, errmsg
    end
    waitio.wait_fd_write(self.nbio_handle.fd)
  end
end

local function wrap_handle(handle)
  return setmetatable(
    {
      nbio_handle = handle,
      read_buffer = "",
    },
    _M.handle_metatbl
  )
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

_M.stdin = wrap_handle(nbio.stdin())
_M.stdout = wrap_handle(nbio.stdout())
_M.stderr = wrap_handle(nbio.stderr())

return _M
