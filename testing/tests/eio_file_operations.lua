local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"

local function r8()
  return math.random(10000000,99999999)
end

local filename = "/tmp/neumond-test-" .. r8() .. "-" ..r8() .. ".file"

local tmp_guard <close> = setmetatable({}, {
  __close = function() os.execute("rm " .. filename) end,
})

local function main(...)
  checkpoint(1)
  local data = tostring(r8())
  do
    local file <close> = assert(eio.open(filename, "w,create,exclusive"))
    file:flush(data)
  end
  do
    local file <close> = assert(eio.open(filename))
    assert(assert(file:read()) == data)
  end
  checkpoint(2)
end

runtime(main)

checkpoint(3)
