local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

eio.stdin:unread("Some more...")
eio.stdin:unread("Hello World!\n")

local function main(...)
  while true do
    local line = assert(eio.stdin:read(40, "\n"))
    if line == "" then
      break
    end
    eio.stdout:flush("Got: ", line, "\n")
  end
  eio.stdout:flush("EOF\n")
end

return runtime(main, ...)
