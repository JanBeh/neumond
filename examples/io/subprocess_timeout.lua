local subprocess = require "subprocess" -- uses fibers
local wait_posix_fiber = require "wait_posix_fiber"
local effect = require "effect"
local fiber = require "fiber"
local wait = require "wait"

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

wait_posix_fiber.main(
  function()
    local hello = assert(exec_timeout("sh", "-c", "echo Hello"))
    assert(hello == "Hello\n")
    local output, errmsg = exec_timeout("sh", "-c", "sleep 2")
    assert(output == nil)
    assert(errmsg == "timeout")
  end
)
