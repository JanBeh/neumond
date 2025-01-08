local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local pgeff = require "neumond.pgeff"

local function main(...)
  checkpoint(1)
  local dbconn <close> = assert(pgeff.connect(""))
  fiber.spawn(function()
    checkpoint(3)
    wait.timeout(0.2)()
    checkpoint(5)
    dbconn:close()
    checkpoint(6)
  end)
  checkpoint(2)
  assert(dbconn:query('SELECT pg_sleep(0.1)'))
  checkpoint(4)
  local success = pcall(function()
    dbconn:query('SELECT pg_sleep(1)')
  end)
  assert(success == false)
  checkpoint(7)
end

runtime(main, ...)

checkpoint(8)
