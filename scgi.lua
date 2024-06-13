-- SCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local fiber = require "fiber"
local wait = require "wait"
local eio = require "eio"
local web = require "web"

_M.max_header_length = 1024 * 256

local request_methods = {}

function request_methods:write(...)
  return self._conn:write(...)
end

function request_methods:flush(...)
  return self._conn:flush(...)
end

function request_methods:read(...)
  if self._request_body_processing then
    error("request body has already been processed", 2)
  end
  return self:_read(...)
end

function request_methods:_read(maxlen, terminator)
  if not self._request_body_unexpected_eof then
    self._request_body_fresh = false
    local remaining = self._request_body_remaining
    if maxlen == nil or maxlen > remaining then
      maxlen = remaining
    end
    local result, errmsg = self._conn:read(maxlen, terminator)
    if not result then
      return result, errmsg
    end
    local resultlen = #result
    self._request_body_remaining = remaining - resultlen
    if
      resultlen >= maxlen or
      terminator == string.sub(result, resultlen, resultlen)
    then
      return result
    end
    self._request_body_unexpected_eof = true
  end
  return nil, "unexpected EOF in request body"
end

function request_methods:process_request_body()
  if self._request_body_processing then
    return
  end
  if not self._request_body_fresh then
    error("request body has already been read", 2)
  end
  self._request_body_processing = true
  local mutex = wait.mutex()
  self._request_body_mutex = mutex
  local guard = mutex()
  fiber.spawn(function()
    local guard <close> = guard
    local body = self:_read()
    local content_type = self.cgi_params.CONTENT_TYPE
    if content_type == "application/x-www-form-urlencoded" then
      self.post_params = web.decode_urlencoded_form(body)
    else
      self.post_params = {}
    end
  end)
end

local request_metatbl = {
  __index = function(self, key)
    if key == "post_params" then
      self:process_request_body()
      do
        local guard <close> = self._request_body_mutex()
      end
      return rawget(self, "post_params")
    end
    return request_methods[key]
  end,
}

local function connection_handler(conn, request_handler)
  local header_len = assert(
    tonumber(string.match(assert(conn:read(16, ":")), "^([0-9]+):")),
    "could not parse SCGI header length"
  )
  assert(header_len <= _M.max_header_length, "SCGI header too long")
  local header = assert(conn:read(header_len))
  assert(#header == header_len, "unexpected EOF in SCGI header")
  local separator = assert(conn:read(1))
  assert(#separator == 1, "unexpected EOF after SCGI header")
  assert(separator == ",", "unexpected byte after SCGI header")
  local params = {}
  for key, value in string.gmatch(header, "([^\0]+)\0([^\0]+)\0") do
    params[key] = value
  end
  local request = setmetatable(
    {
      _conn = conn,
      _request_body_remaining = assert(tonumber(params.CONTENT_LENGTH or 0)),
      _request_body_fresh = true,
      _request_body_processing = false,
      cgi_params = params,
      get_params = web.decode_urlencoded_form(params.QUERY_STRING or ""),
    },
    request_metatbl
  )
  local success, errmsg = xpcall(
    request_handler, debug.traceback, request
  )
  if not success then
    eio.stderr:flush(
      "Error in request handler: " .. tostring(errmsg) .. "\n")
  end
  assert(conn:flush())
end

-- Run SCGI server:
function _M.run(fcgi_path, request_handler)
  -- Listen on local socket:
  local listener = assert(eio.locallisten(fcgi_path))
  while true do
    -- Get incoming connection:
    local conn = listener:accept()
    -- Spawn fiber for connection:
    fiber.spawn(function()
      -- Ensure that connection gets closed when fiber terminates:
      local conn <close> = conn
      -- Execute connection handler and catch errors:
      local success, errmsg = xpcall(
        connection_handler, debug.traceback, conn, request_handler
      )
      -- Check if there was an error in the connection handler:
      if not success then
        -- There was an error in the connection handler:
        -- Print error to application's stderr:
        eio.stderr:flush(
          "Error in connection handler: " .. tostring(errmsg) .. "\n")
      end
    end)
  end
end

return _M
