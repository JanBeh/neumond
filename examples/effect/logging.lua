local effect = require "effect"

local log = effect.new("log")

function foo()
  log("Hello World!")
end

effect.handle(
  {
    [log] = function(resume, message)
      print("LOG: " .. message)
      return resume()
    end,
  },
  function()
    foo()
  end
)
