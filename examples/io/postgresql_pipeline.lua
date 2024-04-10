local waitio_fiber = require "waitio_fiber"
local fiber = require "fiber"
local pgeff = require "pgeff"

return waitio_fiber.main(function()
  local dbconn = assert(pgeff.connect(""))

  local deferred1 = dbconn:query("SELECT 'A'")
  local deferred2 = dbconn:query("SELECT 'B'")

  fiber.spawn(function()
    print("runs second")
    assert(deferred1()[1][1] == 'A')
  end)
  print("runs first")
  assert(deferred2()[1][1] == 'B')
end)
