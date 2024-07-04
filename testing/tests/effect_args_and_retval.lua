local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local expected_message
local log_count = 0

local log = effect.new("log")

function foo()
  checkpoint(2)
  expected_message = "Text A"
  local retval = log("Text A")
  assert(retval == "logged 1")
  checkpoint(4)
  expected_message = "Text B"
  local retval = log("Text B")
  assert(retval == "logged 2")
  checkpoint(6)
end

effect.handle(
  {
    [log] = function(resume, message)
      checkpoint(3, 5)
      assert(message == expected_message)
      log_count = log_count + 1
      return resume("logged " .. log_count)
    end,
  },
  function()
    checkpoint(1)
    foo()
    checkpoint(7)
  end
)

checkpoint(8)
