-- Module for algebraic effect handling

-- Explicitly import certain items from Lua's standard library as local
-- variables for performance improvements to avoid table lookups:
local assert       = assert
local error        = error
local getmetatable = getmetatable
local select       = select
local setmetatable = setmetatable
local tostring     = tostring
local type         = type
local xpcall       = xpcall
local coroutine_close       = coroutine.close
local coroutine_create      = coroutine.create
local coroutine_isyieldable = coroutine.isyieldable
local coroutine_resume      = coroutine.resume
local coroutine_status      = coroutine.status
local coroutine_yield       = coroutine.yield
local debug_traceback = debug.traceback

-- Disallow global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index    = function() error("cannot get global variable", 2) end,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

-- Assert function that does not prepend position information to the error:
local function assert_nopos(success, ...)
  if success then
    return ...
  end
  error(..., 0)
end

-- Default handlers, where each key is an effect and each value is a function
-- that does not get a continuation handle but simply returns the arguments for
-- resuming:
local default_handlers = {}
_M.default_handlers = default_handlers

-- Internally used marker, which indicates that a value passed from the effect
-- handler to the continuation should be called within the inner context, i.e.
-- within the context of the performer:
local call_marker = setmetatable({}, {
  __tostring = function() return "call marker" end,
})

-- Helper function for check_call function:
local function do_call(dummy, func, ...)
  return func(...)
end

-- Function checking coroutine.yield's return values and, if first return value
-- is the call marker, then automatically calling the second return value with
-- the arguments starting at third position:
local function check_call(...)
  if ... == call_marker then
    return do_call(...)
  end
  return ...
end

-- Performs an effect:
local function perform(...)
  -- Check if current coroutine is main coroutine:
  if coroutine_isyieldable() then
    -- Current coroutine is not main coroutine, thus yielding is possible.
    -- Yield from coroutine and process results using check_call function:
    return check_call(coroutine_yield(...))
  end
  -- Current coroutine is main coroutine, thus yielding is not possible.
  -- Check if a default handler is available for the given effect:
  local default_handler = default_handlers[...]
  if default_handler then
    -- A default handler is available.
    -- Call default handler and return its values:
    return default_handler()
  end
  -- No default handler has been found.
  -- Report error:
  error(
    "no effect handler installed while performing effect: " ..
    tostring((...)),
    2
  )
end
_M.perform = perform

-- Convenience function, which creates an object that is suitable to be used as
-- an effect, because it is callable and has a string representation:
function _M.new(name)
  if type(name) ~= "string" then
    error("effect name is not a string", 2)
  end
  local str = name .. " effect"
  return setmetatable({}, {
    __call = perform,
    __tostring = function() return str end,
  })
end

-- Ephemeron holding stack trace information for non-string error objects:
local traces = setmetatable({}, {__mode = "k"})

-- Function adding or storing stack trace to/for error objects:
local function add_traceback(errmsg)
  if type(errmsg) == "string" then
    -- Error message is a string.
    -- Append stack trace to string and return:
    return debug_traceback(errmsg, 2)
  end
  -- Error message is not a string.
  -- Store stack trace in ephemeron, prepending an existing stack trace if one
  -- exists:
  traces[errmsg] = debug_traceback(traces[errmsg], 2)
  -- Return original error object:
  return errmsg
end

-- pcall function that modifies the error object to contain a stack trace (or
-- stores the stack trace if error object is not a string):
local function pcall_traceback(func, ...)
  return xpcall(func, add_traceback, ...)
end

-- Helper function for auto_traceback, acting like assert_nopos but converting
-- error messages to strings and appending stored stack traces (if existing):
local function assert_traceback(success, ...)
  if success then
    return ...
  end
  local errmsg = tostring((...))
  local trace = traces[...]
  if trace then
    error(errmsg .. "\n" .. trace, 0)
  else
    error(errmsg, 0)
  end
end

-- auto_traceback(action, ...) runs action(...) and stringifies any uncaught
-- errors and appends a stack trace if applicable:
function _M.auto_traceback(...)
  return assert_traceback(pcall_traceback(...))
end

-- Metatable for guards, which can auto-discontinue a continuation:
local guard_metatbl = {
  -- Invoked when to-be-closed variable goes out of scope:
  __close = function(self)
    -- Mark as being no longer on stack:
    self.onstack = false
    -- Check if automatic discontinuation is enabled:
    if self.enabled then
      -- Automatic discontinuation is enabled.
      -- Discontinue continuation, i.e. close all to-be-closed variables of
      -- coroutine:
      assert(coroutine_close(self.thread))
    end
  end,
}

-- with_guard(guard, func, ...) calls the passed function func (as tail-call if
-- possible) while ensuring that the continuation guarded by the guard is
-- discontinued when func returns:
local function with_guard(guard, func, ...)
  -- Enable auto-discontinuation:
  guard.enabled = true
  -- Check if guard is already on stack:
  if guard.onstack then
    -- Guard is already on stack.
    -- Simply call function with arguments as tail-call:
    return func(...)
  end
  -- Put guard on stack as to-be-closed variable:
  local guard <close> = guard
  -- Mark guard as being on stack:
  guard.onstack = true
  -- Call function with arguments
  -- (not a tail-call due to to-be-closed variable):
  return func(...)
end

-- Metatable for continuation objects:
local continuation_metatbl = {
  -- Calling a continuation object will resume the interrupted action:
  __call = function(self, ...)
    -- Use guard to call stored resume function with arguments:
    return with_guard(self._guard, self._resume_func, ...)
  end,
  -- Methods of continuation objects:
  __index = {
    -- Calls a function in context of the performer:
    call = function(self, ...)
      -- Use guard to call stored resume function with special call marker as
      -- first argument:
      return with_guard(self._guard, self._resume_func, call_marker, ...)
    end,
    -- Avoids auto-discontinuation on handler return or error:
    persistent = function(self)
      -- Disable automatic discontinuation:
      self._guard.enabled = false
      -- Return self for convenience:
      return self
    end,
    -- Discontinues continuation:
    discontinue = function(self)
      -- Discontinue continuation, i.e. close all to-be-closed variables of
      -- coroutine stored in guard:
      assert(coroutine_close(self._guard.thread))
    end,
  }
}

-- handle(handlers, action, ...) runs action(...) under the context of an
-- effect handler and returns the return value of the action function or
-- of a handler, if a handler was invoked.
--
-- The handlers argument is a table which maps each to-be-handled effect to a
-- function which retrieves a continuation ("resume") as first argument and
-- optionally more arguments from the invocation of the effect.
--
-- The resume object passed to the handler can only be called once and must
-- not be called after the effect handler has returned, unless
-- resume:persistent() is called before the handler returns.
--
function _M.handle(handlers, action, ...)
  -- Create coroutine with pcall_traceback as function:
  local action_thread = coroutine_create(pcall_traceback)
  -- Create and install guard for auto-discontinuation on return:
  local guard <close> = setmetatable(
    {
      thread = action_thread,
      onstack = true,
      enabled = true,
    },
    guard_metatbl
  )
  -- Forward declarations:
  local resume, process_action_results
  -- Function resuming the action:
  local function resume_func(...)
    -- Resume coroutine and use helper function to process multiple return
    -- values:
    return process_action_results(coroutine_resume(action_thread, ...))
  end
  -- Helper function to process return values of coroutine.resume:
  function process_action_results(coro_success, ...)
    -- Check if coroutine.resume failed (should not happen):
    if coro_success then
      -- coroutine.resume did not fail.
      -- Check if coroutine terminated:
      if coroutine_status(action_thread) == "dead" then
        -- Coroutine terminated.
        -- Process return values from pcall_traceback (return results on
        -- success or throw error):
        return assert_nopos(...)
      end
      -- Coroutine did not terminate yet, i.e. an effect has been performed.
      -- Lookup matching handler:
      local handler = handlers[...]
      if handler then
        -- Handler has been found.
        -- Call handler with continuation object:
        return handler(resume, select(2, ...))
      end
      -- No handler has been found.
      -- Check if current coroutine is main coroutine:
      if coroutine_isyieldable() then
        -- Current coroutine is not main coroutine, thus yielding is possible.
        -- Pass yield further down the stack and return its results back up:
        return resume_func(coroutine_yield(...))
      end
      -- Current coroutine is main coroutine, thus yielding is not possible.
      -- Check if a default handler is available for the given effect:
      local default_handler = default_handlers[...]
      if default_handler then
        -- A default handler is available.
        -- Call default handler and resume with its return values:
        return resume_func(default_handler())
      end
      -- No default handler has been found.
      -- Current coroutine is main coroutine and yielding is not possible.
      -- Throw error in context of performer:
      resume:call(error, "unhandled effect or yield: " .. tostring((...)), 0)
    else
      -- coroutine.resume failed.
      error("unhandled error in coroutine: " .. tostring((...)))
    end
  end
  -- Create continuation object:
  resume = setmetatable(
    {
      _guard = guard,
      _resume_func = resume_func,
    },
    continuation_metatbl
  )
  -- Call resume_func with arguments for pcall_traceback:
  return resume_func(action, ...)
end

-- Return module table:
return _M
