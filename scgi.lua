-- FastCGI library

_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

_M.max_header_length = 1024 * 256

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
  for key, value in string.gmatch(header, "([^\0]*)\0([^\0]*)\0") do
    params[key] = value
  end
  local success, errmsg = effect.xpcall(
    request_handler, debug.traceback, conn, params
  )
  if not success then
    eio.stderr:flush(
      "Error in request handler: " .. tostring(errmsg) .. "\n")
  end
  assert(conn:flush())
end

-- SCGI server with missing fiber.scope invocation:
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
        -- Print error to application's stderr:
        eio.stderr:flush(
          "Error in connection handler: " .. tostring(errmsg) .. "\n")
      end
    end)
  end
end

-- Run SCGI server (without waitio_fiber main loop):
function _M.run(...)
  return fiber.scope(run_without_scope, ...)
end

-- Effect terminate_main is used to terminate main function below:
local terminate_main = effect.new("terminate_main")
local terminate_main_handling = { [terminate_main] = function(resume) end }

-- Action for main function below:
local function main_action(...)
  -- Terminate on SIGINT and SIGTERM:
  fiber.spawn(function() eio.catch_signal(2)(); terminate_main() end)
  fiber.spawn(function() eio.catch_signal(15)(); terminate_main() end)
  -- Call run function without a fiber.scope invocation:
  return run_without_scope(...)
end

-- Run SCGI server with waitio_fiber main loop:
function _M.main(...)
  -- NOTE: Handling the terminate_main effect outside waitio_fiber.main allows
  -- to avoid an extra fiber.scope invocation.
  return effect.handle(
    terminate_main_handling, waitio_fiber.main, main_action, ...
  )
end

return _M
