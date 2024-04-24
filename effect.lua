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

-- Special marker indicating that a value passed from the effect handler to the
-- continuation should be called within the inner context, i.e. within the
-- context of the performer:
local call = setmetatable({}, {
  __tostring = function() return "call marker" end,
})
_M.call = call

-- Helper function for check_call function:
local function do_call(dummy, func, ...)
  return func(...)
end

-- Function checking coroutine.yield's return values and, if first return value
-- is the call marker, then automatically calling the second return value with
-- the arguments starting at third position:
local function check_call(...)
  if ... == call then
    return do_call(...)
  else
    return ...
  end
end

-- Performs an effect:
local function perform(...)
  if coroutine_isyieldable() then
    return check_call(coroutine_yield(...))
  end
  error(
    "no effect handler installed while performing effect: " .. tostring((...)),
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

-- Assert function that does not prepend position information to the error:
local function assert_nopos(success, ...)
  if success then
    return ...
  end
  error(..., 0)
end

-- Ephemeron holding stack trace information for non-string error objects:
local traces = setmetatable({}, {__mode = "k"})

-- Function adding or storing stack trace to/for error objects:
local function add_traceback(errmsg)
  -- Check if error message is a string.
  if type(errmsg) == "string" then
    -- Error message is a string.
    --
    return debug_traceback(errmsg, 2)
  end
  -- Error message is not a string.
  -- Store stack trace in ephemeron, prepending an existing stack trace if one
  -- exists:
  traces[errmsg] = debug_traceback(traces[errmsg], 2)
  -- Return original error object:
  return errmsg
end

-- pcall function that modifies the error object to contain a stack trace:
local function pcall_traceback(func, ...)
  return xpcall(func, add_traceback, ...)
end

-- Helper function for auto_traceback, acting like assert but appending stored
-- stack trace (if exists) to error messages:
local function assert_traceback(success, ...)
  if success then
    return ...
  end
  local trace = traces[...]
  if trace then
    error(tostring((...)) .. "\n" .. trace, 0)
  else
    error(..., 0)
  end
end

-- auto_traceback(action, ...) runs action(...) and stringifies any uncaught
-- errors and appends a stack trace if applicable:
function _M.auto_traceback(...)
  return assert_traceback(pcall_traceback(...))
end

-- Ephemeron holding a manager table for a continuation function:
local managers = setmetatable({}, { __mode = "k" })

-- Metatable for continuation manager tables:
local manager_metatbl = {
  -- Invoked when handle function returns:
  __close = function(self)
    -- Check if automatic discontinuation is enabled:
    if self.autoclean then
      -- Automatic discontinuation is enabled.
      -- Discontinue continuation, i.e. close all to-be-closed variables of
      -- coroutine:
      assert(coroutine_close(self.action_thread))
    end
  end,
}

-- handle(handlers, action, ...) runs action(...) under the context of an
-- effect handler and returns the return value of the action function (possibly
-- modified by effect handlers).
--
-- handlers is a table mapping each to-be-handled effect to a function which
-- retrieves a resume function (continuation) as first argument and optionally
-- more arguments from the invocation of the effect.
--
-- The resume function can only be called once and must not be called after the
-- effect handler has returned, unless effect.persist is used on the
-- continuation.
--
function _M.handle(handlers, action, ...)
  -- The action function gets wrapped by the pcall_traceback function to ensure
  -- that errors will contain a stack trace. The arguments to pcall_traceback
  -- (including the action function) are passed on the first "resume".
  local action_thread = coroutine_create(pcall_traceback)
  -- Create manager table, which allows automatic discontinuation:
  local manager <close> = setmetatable(
    {action_thread = action_thread}, manager_metatbl
  )
  -- Function to allow handling coroutine.resume's variable number of return
  -- values:
  local process_action_results
  -- Function resuming the coroutine. On first invocation, the arguments to
  -- pcall_traceback (including the action function) must be passed as first
  -- argument.
  local function resume(...)
    -- Ensure that continuation is discontinued by default when effect handler
    -- returns:
    manager.autoclean = true
    -- Pass all arguments to coroutine.resume and pass all results to
    -- process_action_results function as defined below:
    return process_action_results(coroutine_resume(action_thread, ...))
  end
  -- Memorize manager table for continuation function:
  managers[resume] = manager
  -- Implementation for local variable process_action_results defined above:
  function process_action_results(coro_success, ...)
    -- Check if the coroutine threw an exception (should never happen as it's
    -- supposed to be caught by the pcall_traceback function that has been
    -- passed to coroutine.create):
    if coro_success then
      -- There was no exception caught.
      -- Check if coroutine finished exection:
      if coroutine_status(action_thread) == "dead" then
        -- Coroutine finished execution.
        -- Return coroutine's return values on success or re-throw exception:
        return assert_nopos(...)
      end
      -- Coroutine suspended execution.
      -- Lookup possible handler:
      local handler = handlers[...]
      if handler then
        -- A handler has been found.
        --
        -- The following would ensure that each resume function is only used
        -- once, but the check is ommitted for performance reasons because it
        -- would create a new closure that needs to be garbage collected:
        --
        --local resumed = false
        --local function resume_once(...)
        --  if resumed then
        --    error("cannot resume twice", 2)
        --  end
        --  resumed = true
        --  return resume(...)
        --end
        --return handler(resume_once, select(2, ...))
        --
        -- Instead, the already existing resume closure is returned and
        -- passed to the handler function, followed by the arguments of the
        -- effect invocation:
        return handler(resume, select(2, ...))
      end
      -- No suitable handler has been found.
      -- Check if the current coroutine is the main coroutine:
      if coroutine_isyieldable() then
        -- It is possible to yield again.
        -- Pass yield further down the stack and return its results back up:
        return resume(coroutine_yield(...))
      end
      -- The current coroutine is the main coroutine, thus the effect or
      -- yield cannot be handled and an exception is thrown:
      error("unhandled effect or yield: " .. tostring((...)), 0)
    else
      -- Resuming the coroutine reported an error. This should normally not
      -- happen unless a resume function was used twice.
      error("unhandled error in coroutine: " .. tostring((...)))
    end
  end
  -- Invoke the resume function for the first time, passing the arguments for
  -- pcall_traceback:
  return resume(action, ...)
end

-- persist(resume) makes a resume function persistent, i.e. allows invocation
-- of resume(...) after the effect handler has returned:
function _M.persist(resume)
  -- Obtain manager table of continuation:
  local manager = managers[resume]
  -- Throw error if manager table was not found:
  if not manager then
    error("argument to persist is not a continuation", 2)
  end
  -- Disable automatic closing of coroutine:
  manager.autoclean = false
  -- Return argument for convenience:
  return resume
end

-- discontinue(resume) invalidates a resume function and closes all associated
-- to-be-closed variables:
function _M.discontinue(resume)
  -- Obtain manager table of continuation:
  local manager = managers[resume]
  -- Throw error if manager table was not found:
  if not manager then
    error("argument to discontinue is not a continuation", 2)
  end
  -- Discontinue continuation, i.e. close all to-be-closed variables of
  -- coroutine:
  assert(coroutine_close(manager.action_thread))
end

-- Return module table:
return _M
