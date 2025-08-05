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

  -- Return callable table that resumes the coroutine when called,
  -- but which can also be closed, such that finalizers are run:
  return setmetatable({}, {

    -- Function invoked when handle is called:
    __call = function(self, ...)
      -- If no continuation is stored, then the coroutine is running,
      -- has failed, has been closed, or has terminated successfully:
      if not stored_resume then
        error("cannot resume coroutine", 2)
      end

      -- Get continuation and store nil as continuation:
      local resume = stored_resume
      stored_resume = nil

      -- Resume coroutine by calling continuation with given arguments
      -- and returning any return values:
      return resume(...)
    end,

    -- Function invoked when handle is closed
    -- (using <close> variable):
    __close = function(self)
      -- Check if continuation is stored:
      if stored_resume then
        -- Discontinue continuation (runs finalizers):
        stored_resume:discontinue()
        -- Removed stored continuation:
        stored_resume = nil
      end
    end,

  })

end

do
  local coro <close> = create_coro(function(arg)
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
end

do
  local coro <close> = create_coro(function(arg)
    local guard <close> = setmetatable({}, { __close = function()
      print("Cleanup")
    end })
    yield("X")
    error("should not be reached")
  end)
  assert(coro() == "X")
  -- ending the block will print "Cleanup"
end
