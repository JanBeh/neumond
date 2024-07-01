local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

local function main(...)
  eio.stdout:flush("Hello World!\n")
end

return runtime(main, ...)
