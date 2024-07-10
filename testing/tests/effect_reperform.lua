local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local exception = effect.new("exception")
local check_context = effect.new("check_context")

effect.handle(
  {
    [exception] = function(resume, message)
      assert(message == "some message")
      checkpoint(4)
      resume:call_only(function()
        checkpoint(5)
        local ctx = check_context()
        assert(ctx == "context ok")
        checkpoint(7)
      end)
    end,
  },
  function()
    checkpoint(1)
    effect.handle(
      {
        [exception] = function(resume, message)
          assert(message == "some message")
          checkpoint(3)
          resume:perform(exception, message)
          error("unreachable")
        end,
        [check_context] = function(resume)
          checkpoint(6)
          return resume("context ok")
        end,
      },
      function()
        checkpoint(2)
        exception("some message")
        error("unreachable")
      end
    )
  end
)

checkpoint(8)
