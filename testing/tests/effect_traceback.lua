local checkpoint = require "checkpoint"
local effect = require "neumond.effect"

local store_stacktrace = effect.new("store_stacktrace")

local stacktrace

local function func__outername__()
  checkpoint(1)
  effect.handle(
    {
      [store_stacktrace] = function(resume)
        stacktrace = resume:traceback()
        return resume()
      end,
    },
    function()
      checkpoint(2)
      local function func__middlename__()
        checkpoint(3)
        effect.handle(
          {},
          function()
            checkpoint(4)
            local function func__innername__()
              checkpoint(5)
              store_stacktrace()
              checkpoint(6)
            end
            func__innername__()
            checkpoint(7)
          end
        )
      end
      func__middlename__()
      checkpoint(8)
    end
  )
  checkpoint(9)
end

func__outername__()

assert(string.find(stacktrace, "__innername__"))
assert(string.find(stacktrace, "__middlename__"))
assert(not string.find(stacktrace, "__outername__"))

checkpoint(10)
