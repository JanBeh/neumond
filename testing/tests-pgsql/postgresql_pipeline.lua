local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local pgeff = require "neumond.pgeff"

local function main(...)
  local dbconn <close> = assert(pgeff.connect(""))

  local main_fiber = fiber.current()
  local busy = false

  local queue = {}
  local queue_processor = fiber.spawn(function()
    while true do
      local callback = table.remove(queue, 1)
      if callback then
        callback(dbconn:get_result())
        main_fiber:wake()
      else
        busy = false
        fiber.sleep()
      end
    end
  end)

  function dbconn:query(callback, ...)
    assert(self:send_flush(...))
    queue[#queue+1] = callback
    busy = true
    queue_processor:wake()
  end

  local function callback(res, err)
    assert(res, err)
    wait.timeout(0.2)()
    checkpoint(res[1].cp)
  end
  dbconn:query(callback, "SELECT 2 AS cp")
  dbconn:query(callback, "SELECT 3 AS cp")
  dbconn:query(callback, "SELECT 5 AS cp")

  local function callback(res, err)
    assert(res == nil)
    checkpoint(6, 7)
  end
  dbconn:query(callback, "SELECT error")
  dbconn:query(callback, "SELECT 1")

  dbconn:send_sync()

  local function callback(res, err)
    assert(res, err)
    checkpoint(8)
  end
  dbconn:query(callback, "SELECT 1")

  checkpoint(1)
  wait.timeout(0.5)()
  checkpoint(4)

  while busy do fiber.sleep() end
end

runtime(main, ...)

checkpoint(9)
