local waitio_fiber = require "waitio_fiber"
local fiber = require "fiber"
local pgeff = require "pgeff"

return waitio_fiber.main(function()
  local dbconn = assert(pgeff.connect(""))

  local result1 = dbconn:query("SELECT 'A'")
  local result2 = dbconn:query("SELECT 'B'")

  fiber.spawn(function()
    print("runs second")
    assert(result1[1][1] == 'A')
  end)
  print("runs first")
  assert(result2[1][1] == 'B')
end)
