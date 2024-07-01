local fiber = require "neumond.fiber"
local runtime = require "neumond.runtime"
local pgeff = require "neumond.pgeff"

local function main(...)
  local dbconn = assert(pgeff.connect(""))

  local f1 = fiber.spawn(function()
    local result = dbconn:query("SELECT 15+7 AS val")
    assert(assert(tonumber(result[1].val)) == 22)
  end)
  local f2 = fiber.spawn(function()
    dbconn:close()
  end)
  return f1:await(), f2:await()
end

return runtime(main, ...)
