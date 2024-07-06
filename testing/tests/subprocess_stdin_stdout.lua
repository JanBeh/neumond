local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local head = assert(subprocess.execute_collect(
    "Line one\nLine two\n",
    1024,
    true,
    "head", "-n", "1"
  ))
  assert(head == "Line one\n")
end

return runtime(main, ...)
