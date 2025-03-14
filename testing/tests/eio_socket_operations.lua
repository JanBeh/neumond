local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local wait = require "neumond.wait"
local eio = require "neumond.eio"

local function r8()
  return math.random(10000000,99999999)
end

local path = "/tmp/neumond-test-" .. r8() .. "-" ..r8() .. ".file"

local tmp_guard <close> = setmetatable({}, {
  __close = function() os.execute("rm " .. path) end,
})

local port = math.random(1024, 65535)

local function main(...)
  checkpoint(1)
  do
    local listener <close> = assert(eio.locallisten(path))
    do
      local f = fiber.spawn(function()
        local h <close> = assert(eio.localconnect(path))
        checkpoint(2)
        assert(h:shutdown("data0\n"))
      end)
      local h <close> = assert(listener:accept())
      assert(h:read(nil, "\n") == "data0\n")
      assert(h:read(nil, "\n") == "")
    end
  end
  checkpoint(3)
  do
    local listener <close> = assert(eio.tcplisten("localhost", port))
    do
      local sleeper, waker = wait.notify()
      local f = fiber.spawn(function()
        local h <close> = assert(eio.tcpconnect("localhost", port))
        checkpoint(4)
        assert(h:flush("data1\n"))
        sleeper()
        checkpoint(6)
      end)
      local h <close> = assert(listener:accept())
      assert(h:read(nil, "\n") == "data1\n")
      checkpoint(5)
      waker()
      assert(h:read(nil, "\n") == nil)
    end
    checkpoint(7)
    do
      local f = fiber.spawn(function()
        local h <close> = assert(eio.tcpconnect("localhost", port))
        checkpoint(8)
        assert(h:shutdown("data2\n"))
      end)
      local h <close> = assert(listener:accept())
      assert(h:read(nil, "\n") == "data2\n")
      assert(h:read(nil, "\n") == "")
    end
  end
  checkpoint(9)
end

runtime(main)

checkpoint(10)
