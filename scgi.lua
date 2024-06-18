-- SCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local fiber = require "fiber"
local wait = require "wait"
local eio = require "eio"
local web = require "web"

_M.max_header_length = 1024 * 256

local string_find   = string.find
local string_gmatch = string.gmatch
local string_gsub   = string.gsub
local string_lower  = string.lower
local string_match  = string.match
local string_sub    = string.sub

-- Function parsing parameters of a header value, which must not contain any
-- NULL byte:
local function parse_header_params(s)
  local params = {}
  s = string_gsub(s, '\\"', '\0')
  s = string_gsub(s, '\\(.)', '%1')
  s = string_gsub(s, '([^\0\t ;=]+)[\t ]*=[\t ]*"([^"]*)"', function(k, v)
    params[string_lower(k)] = string_gsub(v, '\0', '"')
    return ""
  end)
  for k, v in string_gmatch(s, '([^\0\t ;=]+)[\t ]*=[\t ]*([^\t ;]*)') do
    params[string_lower(k)] = string_gsub(v, '\0', '"')
  end
  return params
end

local chunk_size = 4096

local function noop()
end

local function stream_until_boundary(handle, boundary, callback)
  local rlen = chunk_size + #boundary - 1
  while true do
    local chunk = handle:_read(rlen)
    if chunk == "" then
      return false
    end
    local pos1, pos2 = string_find(chunk, boundary, 1, true)
    if pos1 then
      handle:_unread(string_sub(chunk, pos2 + 1))
      if pos1 > 1 then
        callback(string_sub(chunk, 1, pos1 - 1))
      end
      return true
    end
    handle:_unread(string_sub(chunk, chunk_size + 1))
    callback(string_sub(chunk, 1, chunk_size))
  end
end

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

function request_methods:unread(...)
  if self._request_body_processing then
    error("request body has already been processed", 2)
  end
  if not self._request_body_unexpected_eof then
    return self._conn:unread(...)
  end
end

function request_methods:_unread(data)
  self._request_body_remaining = self._request_body_remaining + #data
  -- TODO: handle errors?
  return self._conn:unread(data)
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
      terminator == string_sub(result, resultlen, resultlen)
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
    local content_type = self.cgi_params.CONTENT_TYPE or ""
    local ct_base, ct_ext = string_match(content_type, "^([^; \t]*)(.*)")
    ct_base = string_lower(ct_base)
    if ct_base == "application/x-www-form-urlencoded" then
      -- TODO: check maximum request body size
      self.post_params = web.decode_urlencoded_form(self:_read())
    elseif ct_base == "multipart/form-data" then
      local boundary = "--" .. assert(
        parse_header_params(ct_ext).boundary,
        "no multipart/form-data boundary set"
      )
      assert(
        stream_until_boundary(self, boundary, noop),
        "boundary not found in request body"
      )
      local eol = self:_read(1024, "\n")
      assert(
        string_find(eol, "\r\n$"),
        "no linebreak after boundary in multipart form-data request body"
      )
      local boundary = "\r\n" .. boundary
      local post_params = {}
      while true do
        local name
        while true do
          local line = self:_read(nil, "\n")
          if line == "\r\n" or line == "\n" or line == "" then
            break
          end
          local key, value_base, value_ext = string_match(
            line,
            "^([^:]+)[ \t]*:[ \t]*([^; \t]*)([^\0]*)"
          )
          if key then
            key = string_lower(key)
            value_base = string_lower(value_base)
            if key == "content-disposition" and value_base == "form-data" then
              local value_params = parse_header_params(value_ext)
              name = value_params.name
            end
          end
        end
        if name then
          local chunks = {}
          assert(
            stream_until_boundary(self, boundary, function(chunk)
              chunks[#chunks+1] = chunk
            end),
            "unexpected EOF in multipart form-data"
          )
          post_params[name] = table.concat(chunks)
        else
          stream_until_boundary(self, boundary, noop)
        end
        local eol = self:_read(1024, "\n")
        if string.find(eol, "^-%-") then
          break
        end
        assert(
          string_find(eol, "\r\n$"),
          "no linebreak after boundary in multipart form-data request body"
        )
      end
      self.post_params = post_params
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

function _M.connection_handler(conn, request_handler)
  local header_len = assert(
    tonumber(string_match(assert(conn:read(16, ":")), "^([0-9]+):")),
    "could not parse SCGI header length"
  )
  assert(header_len <= _M.max_header_length, "SCGI header too long")
  local header = assert(conn:read(header_len))
  assert(#header == header_len, "unexpected EOF in SCGI header")
  local separator = assert(conn:read(1))
  assert(#separator == 1, "unexpected EOF after SCGI header")
  assert(separator == ",", "unexpected byte after SCGI header")
  local params = {}
  for key, value in string_gmatch(header, "([^\0]+)\0([^\0]+)\0") do
    params[key] = value
  end
  assert(params.SCGI == "1", "missing or unexpected SCGI version")
  local request = setmetatable(
    {
      _conn = conn,
      _request_body_remaining = assert(
        tonumber(params.CONTENT_LENGTH),
        "missing or invalid CONTENT_LENGTH in SCGI header"
      ),
      _request_body_fresh = true,
      _request_body_processing = false,
      cgi_params = params,
      get_params = web.decode_urlencoded_form(params.QUERY_STRING or ""),
    },
    request_metatbl
  )
  local success, errmsg = fiber.scope(
    xpcall, request_handler, debug.traceback, request
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
        _M.connection_handler, debug.traceback, conn, request_handler
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
