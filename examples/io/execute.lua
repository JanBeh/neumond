local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"

local function shell_add(a, b)
  local a = assert(tonumber(a))
  local b = assert(tonumber(b))
  local proc = assert(eio.execute("sh", "-c", "echo $(("..a.."+"..b.."))"))
  local stdout_fiber = fiber.spawn(function()
    return assert(proc.stdout:read())
  end)
  local stderr_fiber = fiber.spawn(function()
    return assert(proc.stderr:read())
  end)
  local stdout = stdout_fiber:await()
  local stderr = stderr_fiber:await()
  local retval = proc:wait()
  if retval ~= 0 then
    print("Standard error output of subprocess:")
    io.stdout:write(stderr)
    print("---")
    if retval < 0 then
      error("Process terminated due to signal " .. -retval .. ".")
    else
      error("Process exited with exit code " .. retval .. ".")
    end
  end
  return assert(tonumber(stdout))
end


waitio_fiber.main(
  function()
    local a = 17
    local b = 4
    local c = shell_add(a, b)
    print(a .. " + " .. b .. " = " .. c)
  end
)
