local effect = require "effect"

local exit = effect.new("exit")

effect.handle(
  {
    [exit] = function(resume)
      -- effect.handle does not require manual discontinuation
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

effect.handle_once(
  {
    [exit] = function(resume)
      -- effect.handle_once requires manual discontinuation:
      effect.discontinue(resume)
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
