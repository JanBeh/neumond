local waitio_fiber = require "waitio_fiber"
local pgeff = require "pgeff"

return waitio_fiber.main(function()
  local dbconn = assert(pgeff.connect(""))

  local a, b = 15, 7
  local result = dbconn:query(
    "SELECT CAST($1 AS INT) + CAST($2 AS INT) AS val", a, b
  )
  if result.error_message then
    error(result.error_message)
  end
  assert(assert(result[1].val) == a + b)
  assert(type(result[1].val) == "number")
  assert(math.type(result[1].val) == "integer")
  assert(result.type_oid.val == 23) -- OID 23 is an INT4

  local result = dbconn:query("SELECT CAST($1 AS INT)", nil)
  if result.error_message then
    error(result.error_message)
  end
  assert(result[1][1] == nil)

  -- expect syntax error (error class "42"):
  local result = dbconn:query("SELEEEECT")
  assert(result.error_code and string.sub(result.error_code, 1, 2) == "42")
end)
