-- Basic I/O library using effects to wait for I/O

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local nbio = require "neumond.nbio"
local wait_posix = require "neumond.wait_posix"

local handle_methods = {}
_M.handle_methods = handle_methods

function handle_methods:close()
  local nbio_handle = self.nbio_handle
  local fd = nbio_handle.fd
  if fd then
    wait_posix.deregister_fd(nbio_handle.fd)
  end
  nbio_handle:close()
end

function handle_methods:shutdown()
  -- NOTE: For some sockets, shutdown may close the file descriptor; thus it is
  -- necessary to call deregister_fd here.
  local nbio_handle = self.nbio_handle
  local fd = nbio_handle.fd
  if fd then
    wait_posix.deregister_fd(nbio_handle.fd)
  end
  return nbio_handle:shutdown()
end

local handle_metatable = {
  __close = handle_methods.close,
  -- NOTE: Closing is not possible during garbage collection, because closing
  -- requires the deregister_fd effect to be handled. The following line is
  -- thus commented out.
  --__gc = handle_methods.close,
  __index = handle_methods,
}
_M.handle_metatable = handle_metatable

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
  while true do
    local result, errmsg = self.nbio_handle:read_unbuffered(maxlen)
    if result == nil then
      return nil, errmsg
    elseif not result then
      return "" -- indicates EOF
    elseif result ~= "" then
      return result
    end
    wait_posix.wait_fd_read(self.nbio_handle.fd)
  end
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
    wait_posix.wait_fd_read(self.nbio_handle.fd)
  end
end

function handle_methods:unread(data, ...)
  local arg_count = select("#", data, ...)
  if arg_count > 1 then
    data = table.concat({data, ...}, nil, 1, arg_count)
  end
  return self.nbio_handle:unread(data)
end

function handle_methods:write(data, ...)
  local arg_count = select("#", data, ...)
  if arg_count > 1 then
    data = table.concat({data, ...}, nil, 1, arg_count)
  end
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
    wait_posix.wait_fd_write(self.nbio_handle.fd)
  end
  return true
end

function handle_methods:flush(data, ...)
  local arg_count = select("#", data, ...)
  if arg_count > 1 then
    data = table.concat({data, ...}, nil, 1, arg_count)
  end
  if data ~= nil and data ~= "" then
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
      wait_posix.wait_fd_write(self.nbio_handle.fd)
    end
  else
    while true do
      local result, errmsg = self.nbio_handle:flush()
      if result == 0 then
        break
      elseif not result then
        return result, errmsg
      end
      wait_posix.wait_fd_write(self.nbio_handle.fd)
    end
  end
  return true
end

local function wrap_handle(handle)
  return setmetatable({ nbio_handle = handle }, handle_metatable)
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
_M.listener_methods = listener_methods

function listener_methods:close()
  local nbio_listener = self.nbio_listener
  local fd = nbio_listener.fd
  if fd then
    wait_posix.deregister_fd(fd)
  end
  nbio_listener:close()
end

local listener_metatable = {
  __close = listener_methods.close,
  -- NOTE: Closing is not possible during garbage collection, because closing
  -- requires the deregister_fd effect to be handled. The following line is
  -- thus commented out.
  --__gc = listener_methods.close,
  __index = listener_methods,
}
_M.listener_metatable = listener_metatable

function listener_methods:accept()
  local nbio_listener = self.nbio_listener
  while true do
    local handle, err = nbio_listener:accept()
    if handle == nil then
      return handle, err
    elseif handle then
      return wrap_handle(handle)
    end
    wait_posix.wait_fd_read(nbio_listener.fd)
  end
end

local function wrap_listener(listener)
  return setmetatable({ nbio_listener = listener }, listener_metatable)
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
_M.child_methods = child_methods

function child_methods:close()
  self.stdin:close()
  self.stdout:close()
  self.stderr:close()
  return self.nbio_child:close()
end

local child_metatable = {
  __close = child_methods.close,
  -- NOTE: Closing is not possible during garbage collection, because closing
  -- requires the deregister_fd effect to be handled. The following line is
  -- thus commented out.
  --__gc = child_methods.close,
  __index = child_methods,
}
_M.child_metatable = child_metatable

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
    wait_posix.wait_pid(pid)
  end
end

local function wrap_child(child)
  return setmetatable(
    {
      nbio_child = child,
      stdin = wrap_handle(child.stdin),
      stdout = wrap_handle(child.stdout),
      stderr = wrap_handle(child.stderr),
    },
    child_metatable
  )
end

function _M.execute(...)
  local child, err = nbio.execute(...)
  if not child then
    return child, err
  end
  return wrap_child(child)
end

_M.catch_signal = wait_posix.catch_signal

_M.stdin = wrap_handle(nbio.stdin)
_M.stdout = wrap_handle(nbio.stdout)
_M.stderr = wrap_handle(nbio.stderr)

return _M
