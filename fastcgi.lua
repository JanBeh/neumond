-- FastCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

local terminate = effect.new("terminate") -- terminate program
local close = effect.new("close") -- close FastCGI connection

local fcgi_rtypes = {
  BEGIN_REQUEST = 1,
  ABORT_REQUEST = 2,
  END_REQUEST = 3,
  PARAMS = 4,
  STDIN = 5,
  STDOUT = 6,
  STDERR = 7,
  DATA = 8,
  GET_VALUES = 9,
  GET_VALUES_RESULT = 10,
  UNKNOWN_TYPE = 11,
}

local fcgi_pstatus = {
  REQUEST_COMPLETE = 0,
  CANT_MPX_CONN = 1,
  OVERLOADED = 2,
  UNKNOWN_ROLE = 3,
}

local fcgi_roles = {
  FCGI_RESPONDER = 1,
}

local fcgi_flags = {
  KEEP_CONN = 1,
}

local function parse_pairs(str)
  local tbl = {}
  local pos = 1
  local str_len = #str
  while pos <= str_len do
    local name_len = ("B"):unpack(str, pos)
    if name_len < 0x80 then
      pos = pos + 1
    else
      assert(pos + 3 <= str_len, "unexpected end in FCGI name-value list")
      name_len, pos = (">I4"):unpack(str, pos) & 0x7fffffff
    end
    assert(pos <= str_len, "unexpected end in FCGI name-value list")
    local value_len = ("B"):unpack(str, pos)
    if value_len < 0x80 then
      pos = pos + 1
    else
      assert(pos + 3 <= str_len, "unexpected end in FCGI name-value list")
      value_len, pos = (">I4"):unpack(str, pos) & 0x7fffffff
    end
    assert(
      pos + name_len + value_len <= str_len + 1,
      "unexpected end in FCGI name-value list"
    )
    local name = string.sub(str, pos, pos+name_len-1)
    pos = pos + name_len
    local value = string.sub(str, pos, pos+value_len-1)
    pos = pos + value_len
    tbl[name] = value
  end
  return tbl
end

local function connection_handler_impl(conn, request_handler)
  local write_mutex = waitio.mutex()
  local requests = {}
  local function send_record_unlocked(rtype, req_id, content)
    assert(conn:write((">BBI2I2Bx"):pack(1, rtype, req_id, #content, 0)))
    assert(conn:write(content))
  end
  local function send_record_flush(...)
    local guard <close> = write_mutex()
    send_record_unlocked(...)
    assert(conn:flush())
  end
  local function end_request(req_id, protocol_status, app_status)
    send_record_flush(
      fcgi_rtypes.END_REQUEST,
      req_id,
      (">I4Bxxx"):pack(app_status, protocol_status)
    )
  end
  local request_metatbl = {
    __index = {
      write = function(self, content)
        local guard <close> = write_mutex()
        send_record_unlocked(fcgi_rtypes.STDOUT, self._req_id, content)
      end,
      write_err = function(self, content)
        send_record_flush(fcgi_rtypes.STDERR, self._req_id, content)
      end,
      flush = function(self, content)
        local guard <close> = write_mutex()
        if content ~= nil and content ~= "" then
          send_record_unlocked(fcgi_rtypes.STDOUT, self._req_id, content)
        end
        assert(conn:flush())
      end,
    }
  }
  local record_handlers = {
    [fcgi_rtypes.GET_VALUES] = function(req_id, content)
      assert(req_id == 0, "FCGI_GET_VALUES with non-zero request ID")
      local tbl = parse_pairs(content)
      local chunks = {}
      for name, value in pairs(tbl) do
        assert(value == "", "value set to non-empty string in FCGI_GET_VALUES")
        if name == "FCGI_MPXS_CONNS" then
          local value = "0"
          chunks[#chunks+1] = (">I4I4"):pack(#name, #value)
          chunks[#chunks+1] = name
          chunks[#chunks+1] = value
        end
      end
      send_record_flush(fcgi_rtypes.GET_VALUES_RESULT, 0, table.concat(chunks))
    end,
    [fcgi_rtypes.BEGIN_REQUEST] = function(req_id, content)
      assert(req_id ~= 0, "FCGI_BEGIN_REQUEST with zero request ID")
      assert(#content >= 3, "insufficient content for FCGI_BEGIN_REQUEST")
      local role, flags = (">I2B"):unpack(content)
      if role ~= fcgi_roles.FCGI_RESPONDER then
        return end_request(req_id, fcgi_pstatus.UNKNOWN_ROLE, 0)
      end
      requests[req_id] = setmetatable(
        {
          _req_id = req_id,
          _params_chunks = {},
          _stdin_chunks = {},
          _keep_conn = flags & fcgi_flags.KEEP_CONN ~= 0,
          stdin_waiter = waitio.waiter(),
          abort_waiter = waitio.waiter(),
        },
        request_metatbl
      )
    end,
    [fcgi_rtypes.ABORT_REQUEST] = function(req_id, content)
      assert(req_id ~= 0, "FCGI_ABORT_REQUEST with zero request ID")
      local request = requests[req_id]
      if request then
        request.abort_waiter.ready = true
      end
    end,
    [fcgi_rtypes.PARAMS] = function(req_id, content)
      assert(req_id ~= 0, "FCGI_PARAMS with zero request ID")
      local request = requests[req_id]
      if request then
        assert(request._params_chunks, "FCGI_PARAMS on closed params")
        if content ~= "" then
          request._params_chunks[#request._params_chunks+1] = content
        else
          request.params = parse_pairs(table.concat(request._params_chunks))
          request._params_chunks = nil
          fiber.spawn(function()
            local status, result = effect.xpcall(
              request_handler, debug.traceback, request
            )
            requests[req_id] = nil
            if not status then
              print("Error in request handler: " .. tostring(result))
              end_request(req_id, fcgi_pstatus.REQUEST_COMPLETE, 1)
            else
              end_request(req_id, fcgi_pstatus.REQUEST_COMPLETE, 0)
            end
            if not request._keep_conn then
              close()
            end
          end)
        end
      end
    end,
    [fcgi_rtypes.STDIN] = function(req_id, content)
      assert(req_id ~= 0, "FCGI_STDIN with zero request ID")
      local request = requests[req_id]
      if request then
        assert(request._stdin_chunks, "FCGI_STDIN on closed stdin")
        if content ~= "" then
          request._stdin_chunks[#request._stdin_chunks+1] = content
        else
          request.stdin = table.concat(request._stdin_chunks)
          request._stdin_chunks = nil
          request.stdin_waiter.ready = true
        end
      end
    end,
  }
  while true do
    local header = assert(conn:read(8))
    if header == "" then break end
    assert(#header == 8, "premature EOF in FastCGI record header")
    local version, rtype, req_id, content_len, padding_len =
      (">BBI2I2B"):unpack(header)
    local content = assert(conn:read(content_len))
    assert(#content == content_len, "premature EOF in FastCGI record content")
    local padding = assert(conn:read(padding_len))
    assert(#padding == padding_len, "premature EOF in FastCGI record padding")
    if version ~= 1 then
      error("unexpected FastCGI protocol version " .. version)
    end
    local record_handler = record_handlers[rtype]
    if record_handler then
      record_handler(req_id, content)
    else
      if req_id == 0 or requests[req_id] then
        send_record_flush(fcgi_rtypes.UNKNOWN_TYPE, req_id, "")
      end
    end
  end
end

local function close_handler(resume)
end
local close_handlers = { [close] = close_handler }
local function connection_handler(...)
  fiber.handle(close_handlers, connection_handler_impl, ...)
end

local function run(fcgi_path, request_handler)
  local listener = assert(eio.locallisten(fcgi_path))
  while true do
    local conn = listener:accept()
    fiber.spawn(function()
      local conn <close> = conn
      local success, errmsg = effect.xpcall(
        connection_handler, debug.traceback, conn, request_handler
      )
      if not success then
        print("Error in handler: " .. tostring(errmsg))
      end
    end)
  end
end

function _M.run(...)
  return fiber.scope(run, ...)
end

function _M.main(...)
  return effect.handle(
    { [terminate] = function(resume) end },
    waitio_fiber.main,
    function(...)
      fiber.spawn(function() eio.catch_signal(2)(); terminate() end)
      fiber.spawn(function() eio.catch_signal(15)(); terminate() end)
      return run(...)
    end,
    ...
  )
end

return _M
