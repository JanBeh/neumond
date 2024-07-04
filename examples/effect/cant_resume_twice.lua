local effect = require "neumond.effect"

local eff1 = effect.new("eff1")
local eff2 = effect.new("eff2")

local saved_resume

effect.handle(
  {
    [eff1] = function(resume)
      saved_resume = resume
      return resume()
    end,
    [eff2] = function(resume)
      -- Using saved_resume should not be allowed,
      -- but it is not caught for performance reasons.
      return saved_resume()
    end,
  },
  function()
    eff1()
    eff2()
  end
)
