local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local log = effect.new("log")

function foo()
  checkpoint(2)
  log("Hello World!")
  checkpoint(4)
end

effect.handle(
  {
    [log] = function(resume, message)
      checkpoint(3)
      assert(message == "Hello World!")
      return resume()
    end,
  },
  function()
    checkpoint(1)
    foo()
    checkpoint(5)
  end
)

checkpoint(6)
