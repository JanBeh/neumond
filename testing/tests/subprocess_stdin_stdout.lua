local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local result = assert(subprocess.execute_collect(
    "Line one\nLine two\n",
    true,
    "head", "-n", "1"
  ))
  assert(result.exitcode == 0)
  assert(result.signal == nil)
  assert(result.stdout == "Line one\n")
  assert(result.stderr == "")
end

return runtime(main, ...)
