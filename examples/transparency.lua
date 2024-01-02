-- This program demonstrates why effect.handle needs to be aware of fibers.

local fiber = require "fiber"
local effect = fiber.effect_mod

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

-- This function is generic and not aware of any effects:
local function do_twice_parallel(...)
  local f1 = fiber.spawn(...)
  local f2 = fiber.spawn(...)
  return f1:await(), (f2:await())
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
    foo()
    fiber.spawn(function()
      for i = 1, 5 do
        log("tock " .. i)
        fiber.yield()
      end
    end)
  end)
end)
