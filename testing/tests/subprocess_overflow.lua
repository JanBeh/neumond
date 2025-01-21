local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local result, errmsg, status = subprocess.execute_collect(
    nil,
    { maxlen = 1 },
    "echo", "ab"
  )
  assert(not result)
  assert(type(errmsg) == "string" and errmsg ~= "")
  assert(status == "overflow")
end

return runtime(main, ...)
