local subprocess = require "neumond.subprocess" -- uses fibers
local runtime = require "neumond.runtime"

local function shell_add(a, b)
  local a = assert(tonumber(a))
  local b = assert(tonumber(b))
  return assert(tonumber(
    assert(subprocess.execute_collect(
      "",
      1024,
      true,
      "sh", "-c", "echo $((" .. a .. "+" .. b.. "))"
    ))
  ))
end

local function main(...)
  local a = 17
  local b = 4
  assert(shell_add(a, b) == 21)
end

return runtime(main, ...)
