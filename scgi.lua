-- SCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local eio = require "eio"

_M.max_header_length = 1024 * 256

local request_methods = {}

function request_methods:write(...)
  return self._conn:write(...)
end

function request_methods:flush(...)
  return self._conn:flush(...)
end

function request_methods:read(maxlen, terminator)
  local remaining = self._remaining
  if maxlen == nil or maxlen > remaining then
    maxlen = remaining
  end
  local result, errmsg = self._conn:read(maxlen, terminator)
  if not result then
    return result, errmsg
  end
  remaining = remaining - #result
  self._remaining = remaining
  if maxlen == nil and terminator == nil and remaining > 0 then
    error("unexpected EOF in request body")
  end
  return result
end

local request_metatbl = {
  __index = request_methods,
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
      _remaining = assert(tonumber(params.CONTENT_LENGTH or 0)),
      cgi_params = params,
    },
    request_metatbl
  )
  local success, errmsg = effect.xpcall(
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
      local success, errmsg = effect.xpcall(
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
