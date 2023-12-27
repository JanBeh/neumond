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

_ENV = setmetatable({}, {
  __index    = function() error("cannot get global variable", 2) end,
  __newindex = function() error("cannot set global variable", 2) end,
})

local _M = {}

local early_return_mt = {
  __tostring = function() return "effect handler did not resume" end,
}
_M.early_return_mt = early_return_mt

local function catch_early_return(...)
  if getmetatable((...)) == early_return_mt then
    error((...))
  else
    return ...
  end
end

function _M.perform(...)
  return catch_early_return(coroutine_yield(...))
end

local children = setmetatable({}, { __mode = "k" })

local function action_wrapper(action, ...)
  return xpcall(action, debug_traceback, ...)
end

function _M.handle(handlers, ...)
  local action_thread = coroutine_create(action_wrapper)
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
          -- This would ensure that each resume function is only used once,
          -- but the check is ommitted for performance reasons because it
          -- would create a new closure that needs to be garbage collected:
          --
          --local resumed = false
          --local function resume_once(...)
          --  if resumed then
          --    error("cannot resume twice", 1)
          --  end
          --  resumed = true
          --  return resume(...)
          --end
          --return handler(resume_once, select(2, ...))
          --
          -- Instead, the already existing resume closure is returned:
          return handler(resume, select(2, ...))
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
  local return_values, error_message
  local early_return_marker = setmetatable({}, early_return_mt)
  local function close(success, ...)
    if coroutine_status(action_thread) == "dead" then
      if success then
        return ...
      end
      if ... == early_return_marker then
        if error_message then
          error(error_message, 0)
        else
          return table_unpack(return_values, 1, return_values.n)
        end
      else
        error(..., 0)
      end
    else
      if success then
        return_values, error_message = table_pack(...), nil
      else
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
        return_values, error_message =
          nil, table_concat(error_parts, "\n", idx, -1)
      end
      return close(xpcall(resume, debug_traceback, early_return_marker))
    end
  end
  return close(xpcall(resume, debug_traceback, ...))
end

local action_threads_cache = setmetatable({}, { __mode = "k" })

local function pass_action_results(resume, coro_success, ...)
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

function _M.handle_once(handlers, ...)
  local action_thread = action_threads_cache[...]
  local resume2
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
          if not resume2 then
            function resume2(...)
              children[coroutine_running()] = action_thread
              return pass_action_results(
                resume2,
                coroutine_resume(action_thread, ...)
              )
            end
            action_threads_cache[resume2] = action_thread
          end
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
  if action_thread then
    resume2 = ...
    return resume(select(2, ...))
  else
    action_thread = coroutine_create(action_wrapper)
    return resume(...)
  end
end

function _M.discontinue(resume)
  local early_return_marker = setmetatable({}, early_return_mt)
  local success, result = xpcall(resume, debug_traceback, early_return_marker)
  if result ~= early_return_marker then
    error(result, 0)
  end
end

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

return _M
