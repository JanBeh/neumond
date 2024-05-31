local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

local function read_background(stream, maxlen)
  return fiber.spawn(function()
    local output = assert(stream:read(maxlen))
    if assert(stream:read(1)) ~= "" then
      error("too much data from child process")
    end
    return output
  end)
end

local function shell_add(a, b)
  local a = assert(tonumber(a))
  local b = assert(tonumber(b))
  local proc = assert(eio.execute("sh", "-c", "echo $(("..a.."+"..b.."))"))
  return fiber.scope(function()
    local stdout_fiber = read_background(proc.stdout, 1024)
    local stderr_fiber = read_background(proc.stderr, 1024*1024)
    local retval = proc:wait()
    if retval ~= 0 then
      print("Standard error output of subprocess:")
      io.stdout:write(stderr_fiber:await())
      print("---")
      if retval < 0 then
        error("Process terminated due to signal " .. -retval .. ".")
      else
        error("Process exited with exit code " .. retval .. ".")
      end
    end
    return assert(tonumber(stdout_fiber:await()))
  end)
end


waitio_fiber.main(
  function()
    local a = 17
    local b = 4
    local c = shell_add(a, b)
    print(a .. " + " .. b .. " = " .. c)
  end
)
