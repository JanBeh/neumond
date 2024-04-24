local effect = require "effect"

local exit = effect.new("exit")

effect.handle(
  {
    [exit] = function(resume)
      -- Exiting from effect handler does not require manual discontinuation.
    end,
  },
  function()
    local cleanup <close> = setmetatable({}, {
      __close = function()
        print("Cleaning up 1")
      end,
    })
    exit()
    print("unreachable")
  end
)

local resume = effect.handle(
  {
    [exit] = function(resume)
      -- effect.persist will disable auto-discontinuation:
      effect.persist(resume)
      -- This allows us to return the continuation function:
      return resume
    end,
  },
  function()
    local cleanup <close> = setmetatable({}, {
      __close = function()
        print("Cleaning up 2")
      end,
    })
    exit()
    print("unreachable")
  end
)
print("Manual cleanup required")
-- Manual cleanup:
effect.discontinue(resume)
