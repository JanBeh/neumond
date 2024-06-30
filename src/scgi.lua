-- SCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local eio = require "neumond.eio"
local web = require "neumond.web"

_M.max_header_length = 1024 * 256

local string_find   = string.find
local string_gmatch = string.gmatch
local string_gsub   = string.gsub
local string_lower  = string.lower
local string_match  = string.match
local string_sub    = string.sub

local decode_uri = web.decode_uri

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

-- Chunk size when streaming request body parts:
_M.streaming_chunk_size = 4096

-- Maximum total size for non-streamed request body parts:
_M.max_non_streamed_size = 1024*1024

local function noop()
end

local function stream_until_boundary(handle, boundary, callback)
  local chunk_size = _M.streaming_chunk_size
  local rlen = chunk_size + #boundary
  while true do
    local chunk = assert(handle:_read(rlen))
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
  local request_body_mode = self._request_body_mode
  if request_body_mode == "auto" then
    error("request body has already been processed", 2)
  elseif request_body_mode == "stream" then
    error("request body streaming function has been set", 2)
  end
  self.request_body_state = "manual"
  return self:_read(...)
end

function request_methods:unread(...)
  local request_body_mode = self._request_body_mode
  if request_body_mode == "auto" then
    error("request body has already been processed", 2)
  elseif request_body_mode == "stream" then
    error("request body streaming function has been set", 2)
  end
  if not self._request_body_unexpected_eof then
    self._request_body_mode = "manual"
    return self._conn:unread(...)
  end
end

function request_methods:_read(maxlen, terminator)
  if not self._request_body_unexpected_eof then
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

function request_methods:_unread(data)
  self._request_body_remaining = self._request_body_remaining + #data
  return self._conn:unread(data)
end

local empty_post_params_array_mt = {
  __index = function(self, key)
    local value = {}
    self[key] = value
    return value
  end,
}

function request_methods:process_request_body()
  local previous_state = self._request_body_mode
  if previous_state == "auto" then
    return
  end
  if previous_state == "manual" then
    error("request body has already been read", 2)
  end
  self._request_body_mode = "auto"
  local mutex = wait.mutex()
  self._request_body_mutex = mutex
  local guard = mutex()
  fiber.spawn(function()
    local guard <close> = guard
    local post_params = {}
    local post_params_array = setmetatable({}, {
      __index = function(self, key)
        local value = { post_params[key] }
        self[key] = value
        return value
      end,
    })
    local post_params_filename = {}
    local post_params_content_type = {}
    local post_params_content_type_params = {}
    self.post_params = post_params
    self.post_params_array = post_params_array
    self.post_params_filename = post_params_filename
    self.post_params_content_type = post_params_content_type
    self.post_params_content_type_params = post_params_content_type_params
    local content_type = self.cgi_params.CONTENT_TYPE or ""
    local ct_base, ct_ext = string_match(content_type, "^([^; \t]*)(.*)")
    ct_base = string_lower(ct_base)
    if ct_base == "application/x-www-form-urlencoded" then
      assert(
        self._request_body_remaining < _M.max_non_streamed_size,
        "request body exceeded maximum length"
      )
      for key, value in
        string.gmatch(assert(self:_read()), "([^&=]+)=([^&=]*)")
      do
        key = decode_uri(key)
        value = decode_uri(value)
        local old_value = post_params[key]
        if old_value then
          local array = post_params_array[key]
          array[#array+1] = value
        else
          post_params[key] = value
        end
      end
    elseif ct_base == "multipart/form-data" then
      local non_streamed_size = 0
      local boundary = "--" .. assert(
        parse_header_params(ct_ext).boundary,
        "no multipart/form-data boundary set"
      )
      assert(
        stream_until_boundary(self, boundary, noop),
        "boundary not found in request body"
      )
      local eol = assert(self:_read(1024, "\n"))
      assert(
        string_find(eol, "\r\n$"),
        "no linebreak after boundary in multipart form-data request body"
      )
      local boundary = "\r\n" .. boundary
      while true do
        local name, content_type, content_type_params
        local header_line_count = 0
        while true do
          local line = assert(self:_read(16384, "\n"))
          if line == "\r\n" or line == "\n" or line == "" then
            break
          end
          if not string_find(line, "\n$") then
            error("too long line in header in multipart form-data part")
          end
          header_line_count = header_line_count + 1
          if header_line_count > 64 then
            error("too many header lines in multipart form-data part")
          end
          line = string_gsub(line, "\r?\n$", "")
          while true do
            local nextline = assert(self:_read(16384, "\n"))
            if not string_find(nextline, "^[\t ]") then
              self:_unread(nextline)
              break
            end
            if not string_find(nextline, "\n$") then
              error("too long line in header in multipart form-data part")
            end
            header_line_count = header_line_count + 1
            if header_line_count > 64 then
              error("too many header lines in multipart form-data part")
            end
            nextline = string_gsub(nextline, "^[\t ]+", "")
            nextline = string_gsub(nextline, "\r?\n$", "")
            line = line .. " " .. nextline
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
              post_params_filename[name] = value_params.filename
            elseif key == "content-type" then
              local value_params = parse_header_params(value_ext)
              content_type = value_base
              content_type_params = value_params
            end
          end
        end
        if name then
          local old_value = post_params[name]
          if not old_value then
            post_params_content_type[name] = content_type
            post_params_content_type_params[name] = content_type_params
          end
          local stream_funcs = self._stream_funcs[name]
          -- TODO: avoid duplicate streaming?
          if stream_funcs then
            if old_value then
              assert(
                stream_until_boundary(self, boundary, noop),
                "unexpected EOF in multipart form-data"
              )
            else
              stream_funcs.init_func(name)
              assert(
                stream_until_boundary(self, boundary, stream_funcs.chunk_func),
                "unexpected EOF in multipart form-data"
              )
              stream_funcs.done_func()
            end
          else
            local chunks = {}
            assert(
              stream_until_boundary(self, boundary, function(chunk)
                non_streamed_size = non_streamed_size + #chunk
                if non_streamed_size > _M.max_non_streamed_size then
                  error(
                    "non-streamed request body parts exceeded maximum length"
                  )
                end
                chunks[#chunks+1] = chunk
              end),
              "unexpected EOF in multipart form-data"
            )
            local value = table.concat(chunks)
            if old_value then
              local array = post_params_array[name]
              array[#array+1] = value
            else
              post_params[name] = value
            end
          end
        else
          stream_until_boundary(self, boundary, noop)
        end
        local eol = assert(self:_read(1024, "\n"))
        if string.find(eol, "^-%-") then
          break
        end
        assert(
          string_find(eol, "\r\n$"),
          "no linebreak after boundary in multipart form-data request body"
        )
      end
    end
  end)
end

function request_methods:setup_stream(name, init_func, chunk_func, done_func)
  local request_body_mode = self._request_body_mode
  if request_body_mode == "auto" then
    error("request body has already been processed", 2)
  elseif request_body_mode == "manual" then
    error("request body has already been read", 2)
  end
  self._request_body_mode = "stream"
  self._stream_funcs[name] = {
    init_func = init_func or noop,
    chunk_func = chunk_func or noop,
    done_func = done_func or noop,
  }
end

function request_methods:await_stream()
  self:process_request_body()
  local _ = self.post_params
end

local body_keys = {
  post_params = true,
  post_params_array = true,
  post_params_filename = true,
  post_params_content_type = true,
  post_params_content_type_params = true,
}

local request_metatbl = {
  __index = function(self, key)
    if body_keys[key] then
      if self._request_body_mode == "stream" then
        error(
          "request body streaming requires explicit request body processing",
          2
        )
      end
      self:process_request_body()
      do
        local guard <close> = self._request_body_mutex()
      end
      return rawget(self, key)
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
  local get_params = {}
  local get_params_array = setmetatable({}, {
    __index = function(self, key)
      local value = { get_params[key] }
      self[key] = value
      return value
    end,
  })
  local query_string = params.QUERY_STRING
  if query_string then
    for key, value in string.gmatch(query_string, "([^&=]+)=([^&=]*)") do
      key = decode_uri(key)
      value = decode_uri(value)
      local old_value = get_params[key]
      if old_value then
        local array = get_params_array[key]
        array[#array+1] = value
      else
        get_params[key] = value
      end
    end
  end
  local request = setmetatable(
    {
      _conn = conn,
      _request_body_remaining = assert(
        tonumber(params.CONTENT_LENGTH),
        "missing or invalid CONTENT_LENGTH in SCGI header"
      ),
      _stream_funcs = {},
      cgi_params = params,
      get_params = get_params,
      get_params_array = get_params_array,
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
