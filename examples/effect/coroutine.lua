-- The effect module implements effects based on Lua's coroutines.
-- This example demonstrates the opposite, i.e. how to implement
-- coroutines based on effects.

-- Use the neumond.effect module:
local effect = require "neumond.effect"

-- Effect for yielding:
local yield = effect.new("yield")

-- Function that creates a coroutine using the given action function
-- and returns a function that resumes the coroutine:
function create_coro(action)

  -- Stored continuation for coroutine:
  local stored_resume

  -- While handling the yield effect, invoke yield effect once
  -- and pass any returned values to the action function:
  effect.handle(
    {
      [yield] = function(resume, ...)
        -- Make continuation persistent and store it for later use:
        stored_resume = resume:persistent()
        -- Return values passed to the yield effect:
        return ...
      end,
    },
    function()
      return action(yield())
    end
  )

  -- Return function that resumes the coroutine:
  return function(...)

    -- If no continuation is stored, then the coroutine is running,
    -- has failed, or has terminated successfully:
    if stored_resume == nil then
      error("cannot resume coroutine", 2)
    end

    -- Get continuation and store nil as continuation:
    local resume = stored_resume
    stored_resume = nil

    -- Resume coroutine by calling continuation with given arguments
    -- and returning any return values:
    return resume(...)

  end

end

local coro = create_coro(function(arg)
  assert(arg == "start arg")
  print(1)
  local v = yield("A")
  assert(v == "resume arg")
  print(3)
  local v = yield("B")
  assert(v == "another resume arg")
  print(5)
  return "done"
end)

local v = coro("start arg")
assert(v == "A")
print("2")
local v = coro("resume arg")
assert(v == "B")
print("4")
local v = coro("another resume arg")
assert (v == "done")
--coro() -- would result in: cannot resume coroutine
