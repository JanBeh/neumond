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

-- Alias for eio.execute:
_M.execute = eio.execute

-- execute_collect(stdin, maxlen, stderr_handler, ...) uses eio.execute(...) to
-- execute a sub-process, writes the stdin string to the subprocess, and
-- collects and returns its stdout (with maxlen bytes) and calls stderr_handler
-- for each line received through stderr:
function _M.execute_collect(stdin, maxlen, stderr_handler, ...)
  local proc, errmsg = eio.execute(...)
  if not proc then
    return nil, errmsg
  end
  return fiber.scope(function()
    if stdin and stdin ~= "" then
      fiber.spawn(function()
        proc.stdin:flush(stdin)
        proc.stdin:close()
      end)
    else
      proc.stdin:close()
    end
    local stdout_fiber = fiber.spawn(function()
      local output, errmsg = proc.stdout:read(maxlen)
      if not output then
        return nil, errmsg
      end
      local extra, errmsg = proc.stdout:read(1)
      if not extra then
        return nil, errmsg
      end
      if extra ~= "" then
        return nil, "too much data from child process"
      end
      return output
    end)
    fiber.spawn(function()
      while true do
        local line = proc.stderr:read(8192, "\n")
        if not line or line == "" then
          break
        end
        if stderr_handler == true then
          if not eio.stderr:flush(line) then
            break
          end
        elseif stderr_handler then
          stderr_handler(line)
        end
        fiber.yield() -- I/O does not always yield
      end
    end)
    local retval = proc:wait()
    if retval ~= 0 then
      if retval < 0 then
        return nil, "process terminated due to signal " .. -retval
      else
        return nil, "process exited with exit code " .. retval
      end
    end
    return stdout_fiber:await()
  end)
end

return _M
