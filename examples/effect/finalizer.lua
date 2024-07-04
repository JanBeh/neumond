local effect = require "neumond.effect"

local early_exit = effect.new("early_exit")

effect.handle(
  {
    [early_exit] = function(resume)
      print("Exiting early.")
      -- resume not used
    end,
  },
  function()
    local guard <close> = setmetatable({}, {
      __close = function()
        print("Cleaning up.") -- this will be executed
      end,
    })
    early_exit()
    error("unreachable")
  end
)
