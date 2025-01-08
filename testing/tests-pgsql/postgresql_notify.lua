local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local pgeff = require "neumond.pgeff"

local function main()
  checkpoint(1)
  local db1 <close> = pgeff.connect("")
  local db2 <close> = pgeff.connect("")
  local listener = fiber.spawn(function()
    while true do
      local notify = assert(db1:listen())
      assert(notify.name == "testevent")
      assert(tonumber(notify.backend_pid), "backend pid not a number")
      local n = assert(tonumber(notify.payload), "payload not a number")
      checkpoint(n)
      if n == 5 then break end
    end
  end)
  fiber.yield()
  checkpoint(2)
  assert(db1:query("LISTEN testevent"))
  checkpoint(3)
  assert(db2:query("NOTIFY testevent, '4'"))
  assert(db2:query("NOTIFY testevent, '5'"))
  listener:await()
  checkpoint(6)
end

runtime(main, ...)

checkpoint(7)
