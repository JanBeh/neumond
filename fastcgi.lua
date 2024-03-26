-- FastCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

-- Constants used in FastCGI protocol:
local fcgi_rtypes = {
  BEGIN_REQUEST = 1, ABORT_REQUEST = 2, END_REQUEST = 3,
  PARAMS = 4, STDIN = 5, STDOUT = 6, STDERR = 7,
  GET_VALUES = 9, GET_VALUES_RESULT = 10,
  UNKNOWN_TYPE = 11,
}
local fcgi_pstatus = { REQUEST_COMPLETE = 0, OVERLOADED = 2, UNKNOWN_ROLE = 3 }
local fcgi_roles = { FCGI_RESPONDER = 1 }
local fcgi_flags = { KEEP_CONN = 1 }

-- Parse FastCGI name-value lists:
local nv_eof_err = "unexpected end in FastCGI name-value list"
local function parse_pairs(str)
  -- Table to be filled with parameter names and their values:
  local tbl = {}
  -- Index of next byte in packed input string to be processed:
  local pos = 1
  -- Total length of packed input string:
  local str_len = #str
  -- Repeat while there are still bytes to process:
  while pos <= str_len do
    -- Attempt to unpack single-byte name length:
    local name_len = ("B"):unpack(str, pos)
    -- Check if MSB is set:
    if name_len < 0x80 then
      -- MSB is not set.
      -- Consume the byte:
      pos = pos + 1
    else
      -- MSB is set.
      -- Assert that there are at least 4 input bytes left:
      assert(pos + 3 <= str_len, nv_eof_err)
      -- Unpack and consume 4-byte name length:
      name_len, pos = (">I4"):unpack(str, pos) & 0x7fffffff
    end
    -- Assert that there is at least 1 input bytes left:
    assert(pos <= str_len, nv_eof_err)
    -- Attempt to unpack single-byte value length:
    local value_len = ("B"):unpack(str, pos)
    -- Check if MSB is set:
    if value_len < 0x80 then
      -- MSB is not set.
      -- Consume the byte:
      pos = pos + 1
    else
      -- MSB is set.
      -- Assert that there are at least 4 input bytes left:
      assert(pos + 3 <= str_len, nv_eof_err)
      -- Unpack and consume 4-byte value length:
      value_len, pos = (">I4"):unpack(str, pos) & 0x7fffffff
    end
    -- Assert that there are enough input bytes left:
    assert(pos + name_len + value_len - 1 <= str_len, nv_eof_err)
    -- Extract name and consume bytes:
    local name = string.sub(str, pos, pos+name_len-1)
    pos = pos + name_len
    -- Extract value and consume bytes:
    local value = string.sub(str, pos, pos+value_len-1)
    pos = pos + value_len
    -- Store name-value pair in table:
    tbl[name] = value
  end
  -- Return table copntaining name-value pairs:
  return tbl
end

-- Effect terminating the connection handler and thus closing the connection:
local close_connection = effect.new("close_connection")

-- Connection handler without handling the close_connection effect:
local function connection_handler_action(conn, request_handler)
  -- Create mutex for sending data to webserver:
  local write_mutex = waitio.mutex()
  -- Table mapping active request IDs to their corresponding request handles:
  local requests = {}
  -- Function sending record to webserver without locking and without flushing:
  local function send_record_unlocked(rtype, req_id, content)
    assert(conn:write((">BBI2I2Bx"):pack(1, rtype, req_id, #content, 0)))
    assert(conn:write(content))
  end
  -- Function sending record to webserver (including flushing):
  local function send_record_flush(...)
    local guard <close> = write_mutex()
    send_record_unlocked(...)
    assert(conn:flush())
  end
  -- Function sending END_REQUEST record to webserver (including flushing):
  local function end_request(req_id, protocol_status, app_status)
    send_record_flush(
      fcgi_rtypes.END_REQUEST,
      req_id,
      (">I4Bxxx"):pack(app_status, protocol_status)
    )
  end
  -- Buffer for STDOUT stream:
  local stdout_buffer = nil
  -- Number of bytes buffered for STDOUT (valid if stdout_buffer ~= nil):
  local stdout_written
  -- Metatable for request handles:
  local request_metatbl = {
    -- Methods of request handles:
    -- TODO: finish STDOUT and STDERR streams with empty content and handle
    --       empty content passed to the methods
    __index = {
      -- Method for buffered writing to STDOUT
      write = function(self, content)
        -- Assert that argument is a string:
        if type(content) ~= "string" then
          error("string expected", 2)
        end
        -- Determine length of content to be written:
        local length = #content
        -- Check if buffered data exists or if content to be written is short
        -- enough to be buffered:
        if stdout_buffer then
          -- Buffered data exists.
          -- Add content to buffer and update its length:
          stdout_buffer[#stdout_buffer+1] = content
          stdout_written = stdout_written + length
          -- If total length is too small, then do not send any record yet:
          if stdout_written < 1024 then return end
          -- Concatenate buffer (concatenated result will be sent):
          content = table.concat(stdout_buffer)
          -- Clear buffer:
          stdout_buffer = nil
        elseif length < 1024 then
          -- No buffered data exists, but content is short enough to be
          -- buffered.
          -- Store content and its length in buffer:
          stdout_buffer = {content}
          stdout_written = length
          -- Do not send any record yet:
          return
        end
        -- Lock mutex for sending data to webserver:
        local guard <close> = write_mutex()
        -- Send content (argument or from buffer) to webserver:
        send_record_unlocked(fcgi_rtypes.STDOUT, self._req_id, content)
      end,
      write_err = function(self, content)
        -- Send content to webserver and flush:
        send_record_flush(fcgi_rtypes.STDERR, self._req_id, content)
      end,
      flush = function(self, content)
        -- Lock mutex for sending data to webserver:
        local guard <close> = write_mutex()
        -- Check if (non-empty) content is passed as argument:
        if content ~= nil and content ~= "" then
          -- Content to be written has been passed as argument.
          -- Assert that argument is a string:
          if type(content) ~= "string" then
            error("string expected", 2)
          end
          -- Check if there is any buffered data.
          if stdout_buffer then
            -- There is buffered data.
            -- Add content to buffer:
            stdout_buffer[#stdout_buffer+1] = content
            -- Concatenate buffer (concatenated result will be sent):
            content = table.concat(stdout_buffer)
            -- Clear buffer:
            stdout_buffer = nil
          end
          -- Send content (argument or from buffer) to webserver:
          send_record_unlocked(fcgi_rtypes.STDOUT, self._req_id, content)
        elseif stdout_buffer then
          -- No (non-empty) content passed to method, but buffer is non-empty.
          -- Concatenate buffer and send to webserver:
          send_record_unlocked(
            fcgi_rtypes.STDOUT, self._req_id, table.concat(stdout_buffer)
          )
          -- Clear buffer:
          stdout_buffer = nil
        end
        -- Flush socket:
        assert(conn:flush())
      end,
    }
  }
  -- Functions that handle different records sent from the webserver:
  local record_handlers = {
    [fcgi_rtypes.GET_VALUES] = function(req_id, content)
      -- Expect a zero request ID:
      assert(req_id == 0, "FCGI_GET_VALUES with non-zero request ID")
      -- Response buffer:
      local chunks = {}
      -- Iterate over all requested variable names:
      for name, value in pairs(parse_pairs(content)) do
        -- Expect that in the request the value is an empty string:
        assert(value == "", "value set to non-empty string in FCGI_GET_VALUES")
        -- Check if variable name is known:
        if name == "FCGI_MPXS_CONNS" then
          -- FCGI_MPXS_CONNS variable value has been requested.
          -- Add response with value "1" to response buffer:
          local value = "1"
          chunks[#chunks+1] = (">I4I4"):pack(#name, #value)
          chunks[#chunks+1] = name
          chunks[#chunks+1] = value
        end
      end
      -- Send response buffer contents as GET_VALUES_RESULT record:
      send_record_flush(fcgi_rtypes.GET_VALUES_RESULT, 0, table.concat(chunks))
    end,
    [fcgi_rtypes.BEGIN_REQUEST] = function(req_id, content)
      -- Expect a non-zero request ID:
      assert(req_id ~= 0, "FCGI_BEGIN_REQUEST with zero request ID")
      -- Expect at least three content bytes:
      assert(#content >= 3, "insufficient content for FCGI_BEGIN_REQUEST")
      -- Unpack FastCGI application role and flags:
      local role, flags = (">I2B"):unpack(content)
      -- Check if application role is unsupported:
      if role ~= fcgi_roles.FCGI_RESPONDER then
        -- Application role is unsupported.
        -- Respond with UNKNOWN_ROLE record and terminate socket connection (by
        -- returning from function):
        return end_request(req_id, fcgi_pstatus.UNKNOWN_ROLE, 0)
      end
      -- Create and store request handle:
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
      -- Expect a non-zero request ID:
      assert(req_id ~= 0, "FCGI_ABORT_REQUEST with zero request ID")
      -- Obtain request handle if exists:
      local request = requests[req_id]
      -- Check if request ID is active:
      if request then
        -- Notify request handler by triggering abort_waiter:
        request.abort_waiter.ready = true
      end
    end,
    [fcgi_rtypes.PARAMS] = function(req_id, content)
      -- Expect a non-zero request ID:
      assert(req_id ~= 0, "FCGI_PARAMS with zero request ID")
      -- Obtain request handle if exists:
      local request = requests[req_id]
      -- Check if request ID is active:
      if request then
        -- Assert that PARAMS stream has not been finished yet:
        assert(request._params_chunks, "FCGI_PARAMS on closed params")
        -- Check if PARAMS stream is terminated (indicated by empty content):
        if content ~= "" then
          -- Stream is not being terminated.
          -- Store content in buffer:
          request._params_chunks[#request._params_chunks+1] = content
        else
          -- Empty content has been received, which indicates end of PARAMS
          -- stream.
          -- Concatenate received chunks, parse name-value pairs, and store as
          -- table in request handle:
          request.params = parse_pairs(table.concat(request._params_chunks))
          -- Memorize that PARAMS stream has terminated:
          request._params_chunks = nil
          -- Spawn fiber with request handler:
          fiber.spawn(function()
            -- Pass request handle to request handler and execute request
            -- handler protectedly (catch errors):
            local status, result = effect.xpcall(
              request_handler, debug.traceback, request
            )
            -- Mark request ID as inactive:
            requests[req_id] = nil
            -- Check if there was an error in the request handler:
            if not status then
              -- There was an error in the request handler.
              -- Print error (TODO: better logging):
              print("Error in request handler: " .. tostring(result))
              -- Send REQUEST_COMPLETE record with non-zero application status:
              end_request(req_id, fcgi_pstatus.REQUEST_COMPLETE, 1)
            else
              -- The request handler terminated successfully.
              -- Send REQUEST_COMPLETE record with zero application status:
              end_request(req_id, fcgi_pstatus.REQUEST_COMPLETE, 0)
            end
            -- Close connection unless KEEP_CONN flag was set:
            if not request._keep_conn then
              close_connection()
            end
          end)
        end
      end
    end,
    [fcgi_rtypes.STDIN] = function(req_id, content)
      -- Expect a non-zero request ID:
      assert(req_id ~= 0, "FCGI_STDIN with zero request ID")
      -- Obtain request handle if exists:
      local request = requests[req_id]
      -- Check if request ID is active:
      if request then
        -- Assert that STDIN stream has not been finished yet:
        assert(request._stdin_chunks, "FCGI_STDIN on closed stdin")
        -- Check if STDIN stream is terminated (indicated by empty content):
        if content ~= "" then
          -- Stream is not being terminated.
          -- Store content in buffer:
          request._stdin_chunks[#request._stdin_chunks+1] = content
        else
          -- Empty content has been received, which indicates end of STDIN
          -- stream.
          -- Concatenate received chunks and store in request handle:
          request.stdin = table.concat(request._stdin_chunks)
          -- Memorize that STDIN stream has terminated:
          request._stdin_chunks = nil
          -- Notify request handler by triggering abort_waiter:
          request.stdin_waiter.ready = true
        end
      end
    end,
  }
  while true do
    -- Read FastCGI record header:
    local header = assert(conn:read(8))
    -- Terminate connection (by returning) on EOF:
    if header == "" then break end
    -- Otherwise, assert there is no EOF until all 8 bytes have been read:
    assert(#header == 8, "premature EOF in FastCGI record header")
    -- Unpack header fields:
    local version, rtype, req_id, content_len, padding_len =
      (">BBI2I2B"):unpack(header)
    -- Read content that is following the header:
    local content = assert(conn:read(content_len))
    -- Assert there is no premature EOF in content:
    assert(#content == content_len, "premature EOF in FastCGI record content")
    -- Read padding:
    local padding = assert(conn:read(padding_len))
    -- Assert there is no premature EOF in padding:
    assert(#padding == padding_len, "premature EOF in FastCGI record padding")
    -- Assert correct protocol version:
    if version ~= 1 then
      error("unexpected FastCGI protocol version " .. version)
    end
    -- Obtain handler for received record type:
    local record_handler = record_handlers[rtype]
    -- Check if record type is supported:
    if record_handler then
      -- Record type is supported.
      -- Invoke handler function for record type:
      record_handler(req_id, content)
    else
      -- Record type is not supported.
      -- Check if record is a management record (zero request ID) or if the
      -- request ID is active:
      if req_id == 0 or requests[req_id] then
        -- Record uses an active request ID or is a management record.
        -- Respond with UNKNOWN_TYPE record:
        send_record_flush(fcgi_rtypes.UNKNOWN_TYPE, req_id, "")
      end
    end
  end
end

-- Invocation of connection_handler while handling the close_connection effect:
local close_connection_handling = { [close_connection] = function(resume) end }
local function connection_handler(...)
  fiber.handle(close_connection_handling, connection_handler_action, ...)
end

-- FastCGI server with missing fiber.scope invocation:
local function run_without_scope(fcgi_path, request_handler)
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
        -- Print error (TODO: better logging):
        print("Error in connection handler: " .. tostring(errmsg))
      end
    end)
  end
end

-- Run FastCGI server (without waitio_fiber main loop):
function _M.run(...)
  return fiber.scope(run_without_scope, ...)
end

-- Effect terminate_main is used to terminate main function below:
local terminate_main = effect.new("terminate_main")
local terminate_main_handling = { [terminate_main] = function(resume) end }

-- Run FastCGI server with waitio_fiber main loop:
function _M.main(...)
  -- NOTE: Handling the terminate_main effect outside waitio_fiber.main allows
  -- to avoid an extra fiber.scope invocation.
  return effect.handle(
    terminate_main_handling,
    waitio_fiber.main,
    function(...)
      -- Terminate on SIGINT and SIGTERM:
      fiber.spawn(function() eio.catch_signal(2)(); terminate_main() end)
      fiber.spawn(function() eio.catch_signal(15)(); terminate_main() end)
      -- Call run function without a fiber.scope invocation:
      return run_without_scope(...)
    end,
    ...
  )
end

return _M
