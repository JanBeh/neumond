local effect = require "effect"

local exit = effect.new("exit")

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
        print("Cleaning up")
      end,
    })
    exit()
    print("unreachable")
  end
)
