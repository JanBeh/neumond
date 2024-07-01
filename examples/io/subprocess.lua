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
  local head = assert(subprocess.execute_collect(
    "Line one\nLine two\n",
    1024,
    true,
    "head", "-n", "1"
  ))
  assert(head == "Line one\n")
  local a = 17
  local b = 4
  local c = shell_add(a, b)
  print(a .. " + " .. b .. " = " .. c)
end

return runtime(main, ...)
