local checkpoint = require "checkpoint"
local runtime = require "neumond.runtime"
local fiber = require "neumond.fiber"

local success, message = pcall(
  function(...)

    local function main(...)
      local custom_error = setmetatable({}, {
        __tostring = function(self) return "custom error" end,
      })
      checkpoint(1)
      local task = fiber.spawn(function()
        checkpoint(3)
      end)
      checkpoint(2)
      task:await()
      checkpoint(4)
      error(custom_error)
    end

    return runtime(main, ...)

  end,
  ...
)

assert(success == false)
assert(string.find(message, "^custom error\r?\n.+"))

checkpoint(5)
