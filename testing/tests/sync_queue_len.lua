local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"
local sync = require "neumond.sync"

runtime(function()
  local q = sync.queue(1)
  assert(#q == 0)
  local f = fiber.spawn(function()
    q:pop()
  end)
  fiber.yield()
  assert(#q == -1)
  f:kill()
  assert(#q == 0)
  q:push("A")
  assert(#q == 1)
  local f = fiber.spawn(function()
    q:push("B")
  end)
  fiber.yield()
  assert(#q == 2)
  f:kill()
  assert(#q == 1)
end)
