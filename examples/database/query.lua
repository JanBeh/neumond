local waitio_fiber = require "waitio_fiber"
local pgeff = require "pgeff"
local fiber = require "fiber"

return waitio_fiber.main(function()
  local dbconn = assert(pgeff.connect(""))

  local result = dbconn:query("SELECT 15+7")
  assert(assert(tonumber(result[1][1])) == 22)

  local res1, res2 = dbconn:query("SELECT 8+3; SELECT 5")
  assert(assert(tonumber(res1[1][1])) == 11)
  assert(assert(tonumber(res2[1][1])) == 5)
end)
