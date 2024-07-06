local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local eio = require "neumond.eio"
local wait = require "neumond.wait"
local wait_posix = require "neumond.wait_posix"

local function r8()
  return math.random(10000000,99999999)
end

local sockname = "/tmp/neumond-test-" .. r8() .. "-" ..r8() .. ".sock"

local tmp_guard <close> = setmetatable({}, {
  __close = function() os.execute("rm " .. sockname) end,
})

local function main(...)
  checkpoint(1)
  local listener = assert(eio.locallisten(sockname))
  local client_conn <close> = assert(eio.localconnect(sockname))
  local server_conn <close> = assert(listener:accept())
  fiber.spawn(function()
    wait.timeout(0.1)()
    server_conn:close()
    checkpoint(5)
  end)
  fiber.spawn(function()
    checkpoint(3)
    client_conn:flush("payload\n")
  end)
  checkpoint(2)
  local line = assert(server_conn:read(1024, "\n"))
  assert(line == "payload\n")
  checkpoint(4)
  wait.timeout(0.2)()
  checkpoint(6)
  local success, result = pcall(function()
    server_conn:read(1024, "\n") -- closed on own side while waiting for I/O
  end)
  assert(success == false)
end

runtime(main)

checkpoint(7)
