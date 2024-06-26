local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"
local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"

local timeout = effect.new("execution timeout")

local function exec_timeout(...)
  return fiber.handle(
    {
      [timeout] = function(resume)
        print("Timeout!")
        return nil, "timeout"
      end,
    },
    function(...)
      fiber.spawn(function()
        wait.timeout(1)()
        timeout()
      end)
      return subprocess.execute_collect("", 1024*1024, true, ...)
    end,
    ...
  )
end

local function main(...)
  local hello = assert(exec_timeout("sh", "-c", "echo Hello"))
  assert(hello == "Hello\n")
  local output, errmsg = exec_timeout("sh", "-c", "sleep 2")
  assert(output == nil)
  assert(errmsg == "timeout")
end

return runtime(main, ...)
