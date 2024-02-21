_ENV = setmetatable({}, { __index = _G })
local _M = {}

local nbio = require "nbio"
local waitio = require "waitio"

local handle_methods = {}

function handle_methods:close()
  waitio.deregister_fd(self.nbio_handle.fd)
  self.nbio_handle:close()
end

function handle_methods:shutdown()
  return self.nbio_handle:shutdown()
end

_M.handle_metatbl = {
  __close = handle_methods.close,
  __gc = handle_methods.close,
  __index = handle_methods,
}

function handle_methods:read_nonblocking(maxlen)
  if maxlen == 0 then
    return ""
  end
  -- EOF is reported as false, no data is reported as ""
  return self.nbio_handle:read_unbuffered(maxlen)
end

function handle_methods:read_unbuffered(maxlen)
  if maxlen == 0 then
    return ""
  end
  for i = 1, 2 do
    local result, errmsg = self.nbio_handle:read_unbuffered(maxlen)
    if result == nil then
      return nil, errmsg
    elseif not result then
      return "" -- indicates EOF
    elseif result ~= "" then
      return result
    end
    if i == 2 then
      break
    end
    waitio.wait_fd_read(self.nbio_handle.fd)
  end
  error("no data available for reading after waiting")
end

function handle_methods:read(maxlen, terminator)
  if maxlen == 0 then
    return ""
  end
  while true do
    local result, errmsg = self.nbio_handle:read(maxlen, terminator)
    if result == nil then
      return nil, errmsg
    elseif not result then
      return "" -- indicates EOF
    elseif result ~= "" then
      return result
    end
    waitio.wait_fd_read(self.nbio_handle.fd)
  end
end

function handle_methods:write(data)
  if data == "" then
    return true
  end
  local start = 1
  local total = #data
  while true do
    local result, errmsg = self.nbio_handle:write(data, start)
    if result then
      start = start + result
    else
      return result, errmsg
    end
    if not (start <= total) then
      break
    end
    waitio.wait_fd_write(self.nbio_handle.fd)
  end
  return true
end

function handle_methods:flush(data)
  if data and data ~= "" then
    -- write_unbuffered also flushes
    local start = 1
    local total = #data
    while true do
      local result, errmsg = self.nbio_handle:write_unbuffered(data, start)
      if result then
        start = start + result
      else
        return result, errmsg
      end
      if not (start <= total) then
        break
      end
      waitio.wait_fd_write(self.nbio_handle.fd)
    end
  else
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
  return true
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

function _M.open(...)
  local handle, err = nbio.open(...)
  if not handle then
    return handle, err
  end
  return wrap_handle(handle)
end

function _M.localconnect(...)
  local handle, err = nbio.localconnect(...)
  if not handle then
    return handle, err
  end
  return wrap_handle(handle)
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

function _M.locallisten(...)
  local listener, err = nbio.locallisten(...)
  if not listener then
    return listener, err
  end
  return wrap_listener(listener)
end

function _M.tcplisten(...)
  local listener, err = nbio.tcplisten(...)
  if not listener then
    return listener, err
  end
  return wrap_listener(listener)
end

local child_methods = {}

function child_methods:close()
  return self.nbio_child:close()
end

_M.child_metatbl = {
  __close = child_methods.close,
  __gc = child_methods.close,
  __index = child_methods,
}

function child_methods:kill(sig)
  return self.nbio_child:kill(sig)
end

function child_methods:wait()
  local pid = self.nbio_child.pid
  while true do
    local result, errmsg = self.nbio_child:wait()
    if result then
      return result
    end
    if result == nil then
      error(errmsg)
    end
    waitio.wait_pid(pid)
  end
end

local function wrap_child(child)
  return setmetatable(
    {
      nbio_child = child,
      stdio = wrap_handle(child.stdio),
      stdout = wrap_handle(child.stdout),
      stderr = wrap_handle(child.stderr),
    },
    _M.child_metatbl
  )
end

function _M.execute(...)
  local child, err = nbio.execute(...)
  if not child then
    return child, err
  end
  return wrap_child(child)
end

_M.catch_signal = waitio.catch_signal

_M.stdin = wrap_handle(nbio.stdin)
_M.stdout = wrap_handle(nbio.stdout)
_M.stderr = wrap_handle(nbio.stderr)

return _M
