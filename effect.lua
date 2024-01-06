-- Module for algebraic effect handling

-- Explicitly import certain items from Lua's standard library as local
-- variables for performance improvements to avoid table lookups:
local error        = error
local getmetatable = getmetatable
local select       = select
local setmetatable = setmetatable
local tostring     = tostring
local type         = type
local xpcall       = xpcall
local coroutine_create      = coroutine.create
local coroutine_isyieldable = coroutine.isyieldable
local coroutine_resume      = coroutine.resume
local coroutine_running     = coroutine.running
local coroutine_status      = coroutine.status
local coroutine_yield       = coroutine.yield
local debug_traceback = debug.traceback
local table_concat = table.concat
local table_pack   = table.pack
local table_unpack = table.unpack

-- Disallow global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index    = function() error("cannot get global variable", 2) end,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

-- Metatable for special "early return markers" passed to the resume function,
-- which indicate that the effect handler does not wish to resume the action:
local early_return_metatbl = {
  __tostring = function() return "effect handler did not resume" end,
}
_M.early_return_metatbl = early_return_metatbl

-- Function filtering coroutine.yield's return values, which turns
-- "early return markers" into exceptions that unwind the stack:
local function catch_early_return(...)
  if getmetatable((...)) == early_return_metatbl then
    error((...))
  else
    return ...
  end
end

-- Performs an effect:
function _M.perform(...)
  if coroutine_isyieldable() then
    return catch_early_return(coroutine_yield(...))
  end
  error(
    "no effect handler installed while performing effect: " .. tostring((...)),
    2
  )
end

-- Convenience function, which creates an object that is suitable to be used as
-- an effect, because it is callable and has a string representation:
function _M.new(name)
  if type(name) ~= "string" then
    error("effect name is not a string", 2)
  end
  local str = name .. " effect"
  return setmetatable({}, {
    __call = _M.perform,
    __tostring = function() return str end,
  })
end

-- Ephemeron aiding to provide better stack traces by storing the
-- last resumed coroutine of every coroutine:
local children = setmetatable({}, { __mode = "k" })

-- Exception handler for actions (functions whose effects are handled), which
-- catches exceptions and adds a stack trace to the error message:
local function action_wrapper(action, ...)
  return xpcall(action, debug_traceback, ...)
end

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
function _M.handle(handlers, ...)
  -- The action function gets wrapped by the action_wrapper function to ensure
  -- that errors will contain a stack trace. The action function is passed to
  -- the action wrapped on the first "resume".
  local action_thread = coroutine_create(action_wrapper)
  -- Function to allow handling coroutine.resume's variable number of return
  -- values:
  local process_action_results
  -- Function resuming the coroutine. On first invocation, action function must
  -- be passed as first argument.
  local function resume(...)
    -- Store current coroutine in children ephemereon for better stack traces:
    children[coroutine_running()] = action_thread
    -- Pass all arguments to coroutine.resume and pass all results to
    -- process_action_results function as defined below:
    return process_action_results(coroutine_resume(action_thread, ...))
  end
  -- Implementation for local variable process_action_results defined above:
  function process_action_results(coro_success, ...)
    -- Check if the coroutine threw an exception (should never happen as it's
    -- supposed to be caught by the action_wrapper function):
    if coro_success then
      -- There was no exception caught.
      -- Check if coroutine finished exection:
      if coroutine_status(action_thread) == "dead" then
        -- Coroutine finished execution.
        -- Check if action_wrapper caught an exception:
        local success, result = ...
        if success then
          -- Return coroutine's return values (except for the first value which
          -- is true to indicate success) because coroutine has returned:
          return select(2, ...)
        end
        -- An error happened during execution of the action function.
        -- Re-throw exception that has been caught by action_wrapper:
        error(result, 0)
      else
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
      end
    else
      -- This should not happen due to the action_wrapper, which catches all
      -- exceptions in the action function.
      error("unhandled error in coroutine: " .. tostring((...)))
    end
  end
  -- Define close function, which expects xpcall's return values when invoking
  -- xpcall(resume, ...). The close function ensures cleanup in case of an
  -- exception or an early return in a handler as well as proper stack traces.
  local return_values, error_message
  local early_return_marker = setmetatable({}, early_return_metatbl)
  local function close(success, ...)
    -- Check if coroutine finished execution or if there was an early return:
    if coroutine_status(action_thread) == "dead" then
      -- Coroutine finished execution.
      -- Check if there was an exception (typically re-thrown by
      -- process_action_results function above):
      if success then
        -- There was no exception.
        -- Return return values:
        return ...
      end
      -- There was an exception.
      -- Check if the exception is an "early return marker" thrown by *this*
      -- closure:
      if ... == early_return_marker then
        -- An "early return marker" thrown by this closure has been caught.
        -- Return memorized return values or re-throw memorized exception:
        if error_message then
          error(error_message, 0)
        else
          return table_unpack(return_values, 1, return_values.n)
        end
      else
        -- The exception is not an "early return marker" or it is an
        -- "early return marker" created by a different closure.
        -- Re-raise the exception:
        error(..., 0)
      end
    else
      -- There was an early return (or an exception in the handler).
      -- Check if there was an exception in the handler:
      if success then
        -- The handler returned normally.
        -- Memorize return values:
        return_values, error_message = table_pack(...), nil
      else
        -- There was an exception in the handler.
        -- Extend error message with stack traces of each involved coroutine's
        -- stack:
        local idx, error_parts = 0, {}
        local this_thread = coroutine_running()
        local thread = children[this_thread]
        while thread and coroutine_status(thread) ~= "dead" do
          idx = idx - 1
          error_parts[idx] = debug_traceback(thread)
          thread = children[thread]
        end
        idx = idx - 1
        error_parts[idx] = debug_traceback(this_thread)
        idx = idx - 1
        error_parts[idx] = tostring(...)
        -- Memorize error message:
        return_values, error_message =
          nil, table_concat(error_parts, "\n", idx, -1)
      end
      -- Throw "early return marker" to unwind the stack of the coroutine:
      return close(xpcall(resume, debug_traceback, early_return_marker))
    end
  end
  -- Invoke resume function for the first time with action function (first
  -- element in "...") passed as first argument, and pass caught exceptions to
  -- close function defined above:
  return close(xpcall(resume, debug_traceback, ...))
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
      local success, result = ...
      if success then
        return select(2, ...)
      end
      error(result, 0)
    else
      if coroutine_isyieldable() then
        return resume(coroutine_yield(...))
      end
      error("unhandled effect or yield: " .. tostring((...)), 0)
    end
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
-- handle_once(handlers, resume, ...) with a resume funcion that has been
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
    children[coroutine_running()] = action_thread
    return process_action_results(coroutine_resume(action_thread, ...))
  end
  function process_action_results(coro_success, ...)
    if coro_success then
      if coroutine_status(action_thread) == "dead" then
        local success, result = ...
        if success then
          return select(2, ...)
        end
        error(result, 0)
      else
        local handler = handlers[...]
        if handler then
          -- Check if resume2 function does already exist:
          if not resume2 then
            -- Create resume2 function, which serves as a resume function that
            -- does not perform further effect handling:
            function resume2(...)
              children[coroutine_running()] = action_thread
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
      end
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
    -- Create new coroutine with action_wrapper:
    action_thread = coroutine_create(action_wrapper)
    -- Use resume function to start coroutine for the first time, in which case
    -- the action needs to be passed as first argument:
    return resume(action, ...)
  end
end

-- Function that invalidates a resume function previously returned by
-- handle_once, and which unwinds the stack and executes finalizers:
function _M.discontinue(resume)
  -- Check if argument is a resume function previously returned by handle_once:
  if not action_threads_cache[resume] then
    -- Argument is not a resume function previously returned by handle_once.
    -- Throw an error:
    error("argument to discontinue is not a continuation", 2)
  end
  -- Argument is a resume function previously returned by handle_once.
  -- Create an "early return marker" and resume coroutine by passing that
  -- marker to the coroutine, which then unwinds the stack by throwing the
  -- marker, and re-catch that marker using xpcall:
  local early_return_marker = setmetatable({}, early_return_metatbl)
  local success, result = xpcall(resume, debug_traceback, early_return_marker)
  -- Check if any exception was caught:
  if success then
    -- No exception was caught, which is unexpected:
    error("discontinued action returned with: " .. tostring(result))
  -- Check if caught exception is the created "early return marker":
  elseif result ~= early_return_marker then
    -- Another exception has been caught.
    -- Re-throw exception:
    error(result, 0)
  end
  -- "early return marker" has been caught successfully.
end

-- Return module table:
return _M
