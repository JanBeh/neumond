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

function handle_methods:read_unbuffered(len)
  waitio.wait_fd_read(self.nbio_handle.fd)
  return self.nbio_handle:read(len)
end

function handle_methods:read(maxlen, terminator)
  -- TODO: improve performance / buffering behavior
  if terminator then
    if #terminator ~= 1 then
      error("terminator must be a single byte", 2)
    end
    terminator = string.gsub(terminator, "[^0-9A-Za-z]", "%%%0")
  end
  local old_chunk = self.read_buffer
  if terminator then
    local pos = string.find(old_chunk, terminator)
    if pos and pos <= maxlen then
      self.read_buffer = string.sub(old_chunk, pos + 1)
      return string.sub(old_chunk, 1, pos)
    end
  end
  local done = #old_chunk
  if maxlen and done >= maxlen then
    self.read_buffer = string.sub(old_chunk, maxlen + 1)
    return string.sub(old_chunk, 1, maxlen)
  end
  local chunks = { old_chunk }
  while not maxlen or done < maxlen do
    local chunk, errmsg = self:read_unbuffered(chunksize)
    if chunk then
      local pos = nil
      if terminator then
        local pos = string.find(chunk, terminator)
        if pos and (not maxlen or done + pos <= maxlen) then
          chunks[#chunks+1] = string.sub(chunk, 1, pos)
          self.read_buffer = string.sub(chunk, pos + 1)
          return table.concat(chunks)
        end
      end
      chunks[#chunks+1] = chunk
      done = done + #chunk
    elseif chunk == nil then
      self.read_buffer = table.concat(chunks)
      return nil, errmsg
    elseif done == 0 then
      return false, errmsg
    else
      break
    end
  end
  if maxlen then
    local all = table.concat(chunks)
    self.read_buffer = string.sub(all, maxlen + 1)
    return (string.sub(all, 1, maxlen))
  else
    self.read_buffer = ""
    return table.concat(chunks)
  end
end

function handle_methods:write_unbuffered(...)
  waitio.wait_fd_write(self.nbio_handle.fd)
  return self.nbio_handle:write(...)
end

function handle_methods:write(data)
  local start = 1
  local total = #data
  while start <= total do
    local result, errmsg = self:write_unbuffered(data, start)
    if result then
      start = start + result
    else
      return result, errmsg
    end
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
