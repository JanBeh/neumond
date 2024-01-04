-- This program demonstrates the use of function fiber.group.

local effect = require "effect"
local fiber = require "fiber"

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
-- to use fiber.group to spawn the fibers in the current context):
local function do_twice_parallel(...)
  -- Spawn fibers in current context, so all installed effect handlers apply:
  return fiber.group(
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

local function foo()
  fiber.spawn(function()
    for i = 1, 5 do
      -- This should run concurrently with fibers spawned outside "foo":
      log("tick " .. i)
      fiber.yield()
    end
  end)
  -- We only want this to be logged specially:
  logging_important(double_hello)
end

fiber.main(function()
  logging(function()
    -- Do not leave this context until all spawned fibers are done, so it is
    -- possible to use the log effect:
    fiber.group(function()
      foo()
      fiber.spawn(function()
        for i = 1, 5 do
          log("tock " .. i)
          fiber.yield()
        end
      end)
    end)
  end)
end)
