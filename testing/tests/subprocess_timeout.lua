local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local result, errmsg, status = subprocess.execute_collect(
    nil,
    { timeout = 0.1 },
    "sleep", "1"
  )
  assert(result == nil)
  assert(type(errmsg) == "string" and errmsg ~= "")
  assert(status == "timeout")
end

return runtime(main, ...)
