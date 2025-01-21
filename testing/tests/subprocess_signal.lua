local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local result = assert(subprocess.execute_collect(
    nil,
    true,
    "sh", "-c", "kill -9 $$"
  ))
  assert(result.exitcode == nil)
  assert(result.signal == 9)
  assert(result.stdout == "")
  assert(result.stderr == "")
end

return runtime(main, ...)
