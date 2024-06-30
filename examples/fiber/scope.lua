-- This program demonstrates the use of nested scopes.

local effect = require "neumond.effect"
local fiber = require "neumond.fiber"

local log = effect.new("log")

-- This function is not aware of any fibers:
local function logging(...)
  return effect.handle({
    [log] = function(resume, message)
      print("LOG: " .. tostring(message))
      return resume()
    end,
  }, ...)
end

-- This function is also not aware of any fibers:
local function logging_important(...)
  -- But uncommenting this line (i.e. using the naive/original effect.handle
  -- function) would stop "Hello World!" from being logged as "IMPORTANT":
  --local effect = require "effect"
  return effect.handle({
    [log] = function(resume, message)
      print("LOG IMPORTANT: " .. tostring(message))
      return resume()
    end,
  }, ...)
end

-- This function is generic and not aware of any particular effects (but needs
-- to use fiber.scope to spawn the fibers in the current context):
local function do_twice_parallel(...)
  -- Spawn fibers in current context, so all installed effect handlers apply:
  return fiber.scope(
    function(...)
      local f1 = fiber.spawn(...)
      local f2 = fiber.spawn(...)
      return f1:await(), (f2:await())
    end,
    ...
  )
end

-- This function is performing but not handling any effects:
local function double_hello()
  do_twice_parallel(function()
    log("Hello World!")
  end)
end

local function task1()
  for i = 1, 5 do
    log("tick " .. i)
    fiber.yield()
  end
end

local function task2()
  -- Only this shall be logged as important:
  logging_important(double_hello)
  -- This shall be logged normally:
  for i = 1, 5 do
    log("tock " .. i)
    fiber.yield()
  end
end

fiber.scope(function()
  logging(function()
    fiber.scope(function()
      local f1 = fiber.spawn(task1)
      local f2 = fiber.spawn(task2)
      f1:try_await()
      f2:try_await()
    end)
  end)
end)
