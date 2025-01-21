-- Easy subprocess execution using fibers

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local eio = require "neumond.eio"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"

-- Alias for eio.execute:
_M.execute = eio.execute

-- Helper functions to be executed as fibers:
local function reader(stream, maxlen)
  local output, errmsg = stream:read(maxlen)
  if not output then return nil, errmsg, "ioerror" end
  local extra, errmsg = stream:read(1)
  if not extra then return nil, errmsg, "ioerror" end
  if extra ~= "" then
    return nil, "too much data from child process", "overflow"
  end
  return output
end
local function writer(stream, data)
  stream:flush(data)
  stream:close()
end

-- Default limits:
local default_limits = { timeout = 60, maxlen = 64*1024*1024 }

-- No limits:
local no_limits = {}

-- execute_collect(stdin, limits, ...) uses eio.execute(...) to execute a
-- sub-process, writes the stdin string to the subprocess, and collects and
-- returns its stdout and stderr. A timeout can be set with limits.timeout in
-- seconds and a limit for the data read from stdout and stderr can be
-- specified with limits.stdout_maxlen and limits.stderr_maxlen (or
-- limits.maxlen for both). If limits is not a table but true, then some
-- default limits apply. Returns a table on success with fields "stdout",
-- "stderr", and "exitcode" or "signal". The second return value is an optional
-- error message (which may be set also when the first return value is a
-- table). The third return value is nil on success or a string being
-- "execfail", "ioerror", "overflow", "timeout", "exitcode", or "signal".
function _M.execute_collect(stdin, limits, ...)
  if not limits then
    limits = no_limits
  elseif limits == true then
    limits = default_limits
  end
  local timeout = limits.timeout
  local stdout_maxlen = limits.stdout_maxlen or limits.maxlen
  local stderr_maxlen = limits.stderr_maxlen or limits.maxlen
  local proc, errmsg = eio.execute(...)
  if not proc then return nil, errmsg, "execfail" end
  return fiber.scope(function()
    local time_exceeded = false
    if timeout then
      fiber.spawn(function()
        wait.timeout(timeout)()
        time_exceeded = true
        proc:kill(9)
      end)
    end
    if stdin and stdin ~= "" then
      fiber.spawn(writer, proc.stdin, stdin)
    else
      proc.stdin:close()
    end
    local stdout_fiber = fiber.spawn(reader, proc.stdout, stdout_maxlen)
    local stderr_fiber = fiber.spawn(reader, proc.stderr, stderr_maxlen)
    local proc_status = proc:wait()
    if time_exceeded then
      return nil, "child process exceeded time limit", "timeout"
    end
    local stdout, errmsg, reader_status = stdout_fiber:await()
    if not stdout then return nil, errmsg, reader_status end
    local stderr, errmsg, reader_status = stderr_fiber:await()
    if not stderr then return nil, errmsg, reader_status end
    local result = { stdout = stdout, stderr = stderr  }
    if proc_status < 0 then
      local signal = -proc_status
      result.signal = signal
      return
        result,
        "child process terminated by signal " .. signal,
        "signal"
    else
      result.exitcode = proc_status
      if proc_status ~= 0 then
        return
          result,
          "child process exited with exitcode " .. proc_status,
          "exitcode"
      end
    end
    return result
  end)
end

return _M
