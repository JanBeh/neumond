local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local sync = require "neumond.sync"

local function maybe_yield()
  if math.random(1, 2) == 1 then
    fiber.yield()
  end
end

for round = 1, 10 do

  local q = sync.queue(math.random(0, 10))

  local n1 = math.random(1, 100)
  local n2 = math.random(1, 100)
  local n3 = math.random(1, n1 + n2 - 1)
  local n4 = n1 + n2 - n3

  local used = {}

  runtime(function()
    local f1 = fiber.spawn(function()
      for i = 1, n1 do
        local e = "element" .. i
        q:push(e)
        used[e] = true
        maybe_yield()
      end
    end)
    local f2 = fiber.spawn(function()
      for i = 1, n2 do
        local e = "element" .. n1 + i
        q:push(e)
        used[e] = true
        maybe_yield()
      end
    end)
    local f3 = fiber.spawn(function()
      for i = 1, n3 do
        local e = q:pop()
        used[e] = nil
        maybe_yield()
      end
    end)
    local f4 = fiber.spawn(function()
      for i = 1, n4 do
        local e = q:pop()
          used[e] = nil
        maybe_yield()
      end
    end)
    f1.name = "f1"
    f2.name = "f2"
    f3.name = "f3"
    f4.name = "f4"
    f1:try_await()
    f2:try_await()
    f3:try_await()
    f4:try_await()
  end)

  assert(next(used) == nil)

end
