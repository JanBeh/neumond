local effect = require "neumond.effect"

local interrupt = effect.new("interrupt")

local resume = effect.handle(
  {
    [interrupt] = function(resume)
      return resume:persistent()
    end,
  },
  function()
    print("1")
    interrupt()
    print("3")
  end
)
print("2")
resume()
