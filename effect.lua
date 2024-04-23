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

-- Metatable for to-be-closed variable that ensures closing of to-be-closed
-- variables of stored coroutine (value for "thread" key):
local coro_cleaner_metatbl = {
  __close = function(self)
    assert(coroutine_close(self.thread))
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
-- effect handler has returned. To be able to use the resume function after the
-- handler has returned, use the handle_once function instead.
--
function _M.handle(handlers, action, ...)
  -- The action function gets wrapped by the pcall_traceback function to ensure
  -- that errors will contain a stack trace. The arguments to pcall_traceback
  -- (including the action function) are passed on the first "resume".
  local action_thread = coroutine_create(pcall_traceback)
  -- Ensure that coroutine's to-be-closed variables will be closed on return:
  local coro_cleaner <close> = setmetatable(
    {thread = action_thread}, coro_cleaner_metatbl
  )
  -- Function to allow handling coroutine.resume's variable number of return
  -- values:
  local process_action_results
  -- Function resuming the coroutine. On first invocation, the arguments to
  -- pcall_traceback (including the action function) must be passed as first
  -- argument.
  local function resume(...)
    -- Pass all arguments to coroutine.resume and pass all results to
    -- process_action_results function as defined below:
    return process_action_results(coroutine_resume(action_thread, ...))
  end
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

-- Ephemeron that allows obtaining the coroutine behind a resume function that
-- has been passed to a handler (needed for tail-call elimination):
local action_threads_cache = setmetatable({}, { __mode = "k" })

-- Function to allow handling coroutine.resume's variable number of return
-- values when invoked in function resume2 in handle_once function:
local function pass_action_results(resume, coro_success, ...)
  -- Same steps as in process_action_results implementations in handle and
  -- handle_once, but do not execute any handler anymore.
  if coro_success then
    if coroutine_status(action_threads_cache[resume]) == "dead" then
      return assert_nopos(...)
    end
    if coroutine_isyieldable() then
      return resume(coroutine_yield(...))
    end
    error("unhandled effect or yield: " .. tostring((...)), 0)
  else
    error("unhandled error in coroutine: " .. tostring((...)))
  end
end

-- handle_once(handlers, action, ...) does the same as
-- handle(handlers, action, ...) but returns a resume function that does not
-- include further effect handling and which does not get invalidated when an
-- effect handler returns.
--
-- Tail-call optimization is done when invoking
-- handle_once(handlers, resume, ...) with a resume function that has been
-- previously returned by handle_once.
--
-- No cleanup work is done if an effect handler in the handlers table passed to
-- handle_once returns early or throws an exception. Manually calling
-- discontinue(resume) is necessary to properly unwind the stack and execute
-- finalizers.
--
function _M.handle_once(handlers, action, ...)
  -- Check if the action function is a resume function that has been previously
  -- passed to an effect handler, and extract the corresponding coroutine in
  -- that case:
  local action_thread = action_threads_cache[action]
  -- Modified resume function that does no longer perform effect handling:
  local resume2
  -- Same implementation as in handle function, but create, store, and pass
  -- resume2 function to handler instead:
  local process_action_results
  local function resume(...)
    return process_action_results(coroutine_resume(action_thread, ...))
  end
  function process_action_results(coro_success, ...)
    if coro_success then
      if coroutine_status(action_thread) == "dead" then
        return assert_nopos(...)
      end
      local handler = handlers[...]
      if handler then
        -- Check if resume2 function does already exist:
        if not resume2 then
          -- Create resume2 function, which serves as a resume function that
          -- does not perform further effect handling:
          function resume2(...)
            return pass_action_results(
              resume2,
              coroutine_resume(action_thread, ...)
            )
          end
          -- Store coroutine associated to created resume2 function in
          -- ephemeron to enable reusing the coroutine for tail-call
          -- elimination:
          action_threads_cache[resume2] = action_thread
        end
        -- resume2 function exists at this point.
        -- Use resume2 function when invoking handler:
        return handler(resume2, select(2, ...))
      end
      if coroutine_isyieldable() then
        return resume(coroutine_yield(...))
      end
      error("unhandled effect or yield: " .. tostring((...)), 0)
    else
      error("unhandled error in coroutine: " .. tostring((...)))
    end
  end
  -- Branch depending on whether action is a previously returned resume
  -- function:
  if action_thread then
    -- action is a previously returned resume function.
    -- Use action as resume2 function:
    resume2 = action
    -- Use resume function to resume coroutine, which performs effect handling
    -- once:
    return resume(...)
  else
    -- action is not a previously returned resume function.
    -- Create new coroutine with pcall_traceback:
    action_thread = coroutine_create(pcall_traceback)
    -- Use resume function to start coroutine for the first time, in which case
    -- the action needs to be passed as first argument:
    return resume(action, ...)
  end
end

-- Function that invalidates a resume function previously returned by
-- handle_once, and which unwinds the stack and executes finalizers:
function _M.discontinue(resume)
  -- Obtain coroutine from resume function (succeeds if it is a resume function
  -- created by handle_once):
  local action_thread = action_threads_cache[resume]
  -- Check if coroutine could be obtained.
  if not action_thread then
    -- Argument is not a resume function created by handle_once.
    -- Throw an error:
    error("argument to discontinue is not a continuation", 2)
  end
  -- Close to-be-closed variables of coroutine:
  assert(coroutine_close(action_thread))
end

-- Return module table:
return _M
