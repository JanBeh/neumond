local effect = require "neumond.effect"

local log = effect.new("log")

-- Install default handler for log effect:
effect.default_handlers[log] = function()
  -- do nothing
  -- NOTE: Default handlers resume implicitly on return.
end

-- Handler for log effect:
local function verbose_log_handler(resume, message)
  print("LOG: " .. message)
  return resume()
end

-- Execute with handler for log effect:
local function verbose(...)
  return effect.handle({ [log] = verbose_log_handler }, ...)
end

-- Function that uses log effect:
function foo(n)
  log("Hello World " .. tostring(n) .. "!")
end

foo(1) -- This doesn't log.
verbose(function()
  foo(2) -- This gets logged.
end)
