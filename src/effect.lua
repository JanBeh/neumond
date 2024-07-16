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
local coroutine_create      = coroutine.create
local coroutine_isyieldable = coroutine.isyieldable
local coroutine_resume      = coroutine.resume
local coroutine_running     = coroutine.running
local coroutine_status      = coroutine.status
local coroutine_yield       = coroutine.yield
local debug_traceback = debug.traceback
local table_concat = table.concat

-- Disallow global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index    = function() error("cannot get global variable", 2) end,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

-- Metatable for private ephemerons:
local weak_mt = {__mode = "k"}

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
local default_handlers = setmetatable({}, {__mode = "k"})
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
  -- Check if yielding is possible:
  if coroutine_isyieldable() then
    -- Yielding is possible.
    -- Yield from coroutine and process results using check_call function:
    return check_call(coroutine_yield(...))
  end
  -- Yielding is not possible.
  -- Check if current coroutine is main coroutine:
  local current_coro, is_main = coroutine_running()
  if is_main then
    -- Current coroutine is main coroutine, thus no effect handlers are
    -- installed.
    -- Check if a default handler is available for the given effect:
    local default_handler = default_handlers[...]
    if default_handler then
      -- A default handler is available.
      -- Call default handler and return its values:
      return default_handler(select(2, ...))
    end
    -- No default handler has been found.
    error(
      "no effect handler installed while performing effect: " ..
      tostring((...)),
      2
    )
  else
    -- Current coroutine is not main coroutine, but yielding is not possible
    -- due to C-call boundaries.
    error(
      "cannot yield across C-call boundary while performing effect: " ..
      tostring((...)),
      2
    )
  end
end
_M.perform = perform

-- Convenience function, which creates an object that is suitable to be used as
-- an effect, because it is callable and has a string representation:
local function new(name)
  if type(name) ~= "string" then
    error("effect name is not a string", 2)
  end
  local str = name .. " effect"
  return setmetatable({}, {
    __call = perform,
    __tostring = function() return str end,
  })
end
_M.new = new

-- Error used to unwind the stack of a coroutine:
local discontinued = setmetatable({}, {
  __tostring = function() return "action discontinued" end,
})

-- Ephemeron holding stack trace information for non-string error objects:
local traces = setmetatable({}, weak_mt)

-- Function adding or storing stack trace to/for error objects:
local function add_traceback(errmsg)
  -- Check if error message is a discontinuation of an action:
  if errmsg == discontinued then
    -- Error message is a discontinuation error. Discontinuations should always
    -- be caught, thus no stack trace needs to be generated.
    -- Return original error object:
    return errmsg
  end
  local errtype = type(errmsg)
  -- Check if error message is a string:
  if errtype == "string" then
    -- Error message is a string.
    -- Append stack trace to string and return:
    return debug_traceback(errmsg, 2)
  end
  -- Error message is not a string.
  -- Check if error message is not nil and not a number:
  if errmsg ~= nil and errtype ~= "number" then
    -- Error message is a table, userdata, function, thread, or boolean.
    -- Store stack trace in ephemeron, prepending an existing stack trace if
    -- one exists:
    traces[errmsg] = debug_traceback(traces[errmsg], 2)
  end
  -- Return original error object:
  return errmsg
end

-- pcall function that modifies the error object to contain a stack trace (or
-- stores the stack trace if error object is not a string):
local function pcall_traceback(func, ...)
  return xpcall(func, add_traceback, ...)
end

-- Helper function for pcall function:
local function process_pcall_results(success, ...)
  if success or ... ~= discontinued then
    return success, ...
  end
  error(..., 0)
end

-- Function like Lua's pcall, but re-throwing any "discontinued" error and
-- adding or storing a traceback to/for the error message:
function _M.pcall(...)
  return process_pcall_results(pcall_traceback(...))
end

-- Function that turns an error message (which can be a table) into a string:
local function stringify_error(message)
  local trace = traces[message]
  local message = tostring(message)
  if trace then
    return message .. "\n" .. trace
  else
    return message
  end
end
_M.stringify_error = stringify_error

-- Helper function for stringify_errors function:
local function process_stringify_errors_results(success, ...)
  if success then
    return ...
  end
  if ... ~= discontinued then
    error(stringify_error((...)), 0)
  else
    error(..., 0)
  end
end

-- stringify_errors(action, ...) runs action(...) and stringifies any uncaught
-- errors (except for discontinuation errors) and appends a stack trace if
-- applicable:
function _M.stringify_errors(...)
  return process_stringify_errors_results(pcall_traceback(...))
end

-- Helper function for pcall_stringify_errors function:
local function process_pcall_stringify_errors_results(success, ...)
  if success then
    return success, ...
  end
  if ... ~= discontinued then
    return success, stringify_error((...))
  end
  error(..., 0)
end

-- pcall_stringify_errors(...) is equivalent to _M.pcall(stringify_errors(...)) but
-- more efficient:
function _M.pcall_stringify_errors(...)
  return process_pcall_stringify_errors_results(pcall_traceback(...))
end

-- Ephemeron mapping continuations to states, which interally represent the
-- continuation and hold some private attributes:
local states = setmetatable({}, weak_mt)

-- state_resume(state, ...) calls state.resume_func (as tail-call if possible)
-- while ensuring that the continuation is discontinued when resume_func
-- returns:
local function state_resume(state, ...)
  -- Check if coroutine is being closed:
  if state.closing then
    -- Coroutine is being closed.
    -- Simply call function with arguments as tail-call:
    return state.resume_func(...)
  end
  -- Coroutine is not being closed.
  -- Enable auto-discontinuation:
  state.auto_discontinue = true
  -- Check if state is already on stack as to-be-closed variable:
  if state.onstack then
    -- State is already on stack as to-be-closed variable.
    -- Simply call function with arguments as tail-call:
    return state.resume_func(...)
  end
  -- Coroutine is not being closed and state is not on stack.
  -- Put state on stack as to-be-closed variable:
  local state <close> = state
  -- Mark state as being on stack:
  state.onstack = true
  -- Call function with arguments
  -- (not a tail-call due to to-be-closed variable):
  return state.resume_func(...)
end

-- state_perform(state, eff, ...) (re-)performs an effect eff in the context of
-- the continuation, which is necessary to pass effects down the stack:
local function state_perform(state, ...)
  -- Check if yielding is possible:
  if coroutine_isyieldable() then
    -- Yielding is possible.
    -- Yield further down the stack and return results back up:
    return state.resume_func(coroutine_yield(...))
  end
  -- Yielding is not possible.
  -- Check if current coroutine is main coroutine:
  local current_coro, is_main = coroutine_running()
  if is_main then
    -- Current coroutine is main coroutine, thus no effect handler has been
    -- found.
    -- Check if a default handler is available for the given effect:
    local default_handler = default_handlers[...]
    if default_handler then
      -- A default handler is available.
      -- Call default handler and resume with its return values:
      return state.resume_func(default_handler())
    end
    -- No default handler has been found.
    -- Throw error in context of performer:
    state_resume(
      state, call_marker,
      error, "unhandled effect or yield: " .. tostring((...)), 2
    )
  else
    -- Current coroutine is not main coroutine, but yielding is not
    -- possible due to C-call boundaries.
    -- Throw error in context of performer:
    state_resume(
      state, call_marker,
      error,
      "cannot yield across C-call boundary while performing effect: " ..
      tostring((...)),
      2
    )
  end
end

-- Function closing a state's coroutine:
local function state_close(state)
  -- Mark as closing:
  state.closing = true
  -- Check if coroutine is still running:
  if coroutine_status(state.thread) ~= "dead" then
    -- Coroutine is still running.
    -- NOTE: Using coroutine.close does not allow finalizers to yield (due to a
    -- C-call boundary), thus we need to close the coroutine by throwing an
    -- error.
    -- Close corouine by throwing a "discontinued" error within the coroutine
    -- and catching the error here:
    local success, errmsg = pcall_traceback(
      state.resume_func, call_marker, error, discontinued
    )
    -- Check if "discontinued" error was caught:
    if success then
      -- No error was caught.
      -- Report an error:
      error("error used for unwinding stack of coroutine was caught", 0)
    elseif errmsg ~= discontinued then
      -- Another error was caught.
      -- Re-throw error:
      error(errmsg, 0)
    end
  end
end

-- Metatable for internal states:
local state_metatbl = {
  -- Invoked when to-be-closed variable goes out of scope:
  __close = function(self)
    -- Check if automatic discontinuation is enabled:
    if self.auto_discontinue then
      -- Automatic discontinuation is enabled.
      -- NOTE: It is not necessary to mark state as not being on stack.
      -- Close coroutine:
      state_close(self)
    else
      -- Automatic discontinuation is disabled.
      -- Mark as being no longer on stack:
      self.onstack = false
    end
  end,
}

-- Effect used to call a function in context of performer without resuming:
local no_resume = new("neumond.effect.no_resume")
local no_resume_handlers = {
  [no_resume] = function(resume, ...)
    resume:persistent()
    return ...
  end,
}

-- Effect used to generate tracebacks of a continuation:
local traceback = new("neumond.effect.traceback")

-- Forward declaration:
local handle

-- Metatable for exposed continuation objects:
local continuation_metatbl = {
  -- Calling a continuation object will resume the interrupted action:
  __call = function(self, ...)
    -- Ensure auto-discontinuation and call stored resume function with
    -- arguments:
    return state_resume(states[self], ...)
  end,
  -- Methods of continuation objects:
  __index = {
    -- Calls a function in context of the performer and resumes with its
    -- results:
    call = function(self, ...)
      -- Ensure auto-discontinuation and call stored resume function with
      -- special call marker as first argument:
      return state_resume(states[self], call_marker, ...)
    end,
    -- Calls a function in context of the performer and does not resume but
    -- returns its results:
    call_only = function(self, ...)
      -- Like :call method, but use no_resume effect to exit resumed coroutine
      -- after calling the passed function:
      return handle(
        no_resume_handlers,
        state_resume, states[self], call_marker,
        function(func, ...)
          return no_resume(func(...))
        end,
        ...
      )
    end,
    -- Returns a traceback of the continuation:
    traceback = function(self)
      -- Perform traceback effect in context of continuation with necessary
      -- arguments, and concatenate parts of traceback into one string:
      return table_concat(
        self:call_only(traceback, states[self].thread, {}),
        "\n"
      )
    end,
    -- Re-performs an effect in the context of the continuation:
    perform = function(self, ...)
      return state_perform(states[self], ...)
    end,
    -- Avoids auto-discontinuation on handler return or error:
    persistent = function(self)
      -- Disable automatic discontinuation:
      states[self].auto_discontinue = false
      -- Return self for convenience:
      return self
    end,
    -- Discontinues continuation:
    discontinue = function(self)
      -- Close coroutine:
      state_close(states[self])
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
function handle(handlers, action, ...)
  -- Create coroutine with pcall_traceback as function:
  local action_thread = coroutine_create(pcall_traceback)
  -- Forward declarations:
  local resume, process_action_results, state
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
      -- Check if traceback effect has been performed:
      if ... == traceback then
        -- Internal effect "traceback" has been performed.
        -- Obtain arguments:
        local dummy_, until_thread, parts = ...
        -- Extend stack trace parts:
        local part_count = #parts
        if part_count == 0 then
          parts[1] = debug_traceback(action_thread, nil, 3)
        else
          parts[#parts+1] = debug_traceback(action_thread)
        end
        -- Check if end level (of nested coroutines) has been reached:
        if action_thread == until_thread then
          -- End level has been reached.
          -- Resume with stack trace parts:
          return resume_func(parts)
        end
        -- End level has not been reached and traceback effect must be
        -- re-performed.
      end
      -- Re-perform effect:
      return state_perform(state, ...)
    else
      -- coroutine.resume failed.
      error("unhandled error in coroutine: " .. tostring((...)))
    end
  end
  -- Create and install state for auto-discontinuation on return:
  state = setmetatable(
    {
      resume_func = resume_func,
      thread = action_thread,
      onstack = true,
      auto_discontinue = true,
      closing = false,
    },
    state_metatbl
  )
  local state <close> = state
  -- Create continuation object and associate state:
  resume = setmetatable({}, continuation_metatbl)
  states[resume] = state
  -- Call resume_func with arguments for pcall_traceback:
  return resume_func(action, ...)
end
_M.handle = handle

-- Return module table:
return _M
