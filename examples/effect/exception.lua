local effect = require "neumond.effect"

local exception = effect.new("exception")

local function catch_impl(traceback, action, kind, handler)
  local pattern = "^" .. string.gsub(kind, "%.", "%%.") .. "%f[.\0]"
  return effect.handle(
    {
      [exception] = function(resume, ex)
        if string.find(ex.kind, pattern) then
          if traceback then
            -- TODO: debug.traceback contains current coroutine only
            return handler(ex, resume:call_only(debug.traceback))
          else
            return handler(ex)
          end
        else
          return resume:perform(exception, ex)
        end
      end,
    },
    action
  )
end

local function catch_with_traceback(...)
  return catch_impl(true, ...)
end

local function catch(...)
  return catch_impl(false, ...)
end

local function foo()
  exception{ kind = "runtime.foo", message = "Foo exception" }
end

local function outer()

  local retval = catch_with_traceback(
    function()
      catch(
        function()
          foo()
        end,
        "io",
        function(ex)
          print("I/O exception caught: " .. ex.message)
        end
      )
      error("unreachable")
      return true
    end,
    "runtime",
    function(ex, stack)
      print("Runtime exception caught: " .. ex.message)
      print(stack)
      return false
    end
  )

  assert(retval == false)

end

outer()

print()
print("Terminating.")
