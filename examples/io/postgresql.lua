local waitio_fiber = require "waitio_fiber"
local pgeff = require "pgeff"

return waitio_fiber.main(function()
  local dbconn = assert(pgeff.connect(""))

  local result = dbconn:query("SELECT 15+7 AS val")
  assert(assert(tonumber(result[1].val)) == 22)

  local res1, res2 = dbconn:query("SELECT 8+3 AS val; SELECT 5")
  assert(assert(tonumber(res1[1].val)) == 11)
  assert(assert(tonumber(res2[1][1])) == 5)
end)
