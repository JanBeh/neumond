local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function main(...)
  local result, errmsg, status = subprocess.execute_collect(
    nil, nil, "/doesnotexist_xxx"
  )
  assert(not result)
  assert(type(errmsg) == "string" and errmsg ~= "")
  assert(status == "execfail")
end

return runtime(main, ...)
