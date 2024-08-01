-- Module for lightweight threads (fibers)

-- Explicitly import certain items from Lua's standard library as local
-- variables for performance improvements to avoid table lookups:
local error        = error
local ipairs       = ipairs
local next         = next
local setmetatable = setmetatable
local pairs        = pairs
local table_insert = table.insert
local table_pack   = table.pack
local table_unpack = table.unpack

-- Import some items from effect module as local variables:
local effect_new
local effect_default_handlers
local effect_handle
do
  local effect = require "neumond.effect"
  effect_new              = effect.new
  effect_default_handlers = effect.default_handlers
  effect_handle           = effect.handle
end

-- Import "yield" module (which is used as "yield" effect):
local yield = require "neumond.yield"

-- Disallow global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index    = function() error("cannot get global variable", 2) end,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

-- Explicitly import certain items as local variables for performance
-- improvements to avoid table lookups:
local error = error
local setmetatable = setmetatable
-- Function creating a FIFO-like data structure where there can be no
-- duplicates (i.e. pushing an already existing element is a no-op):
local function fifoset()
  local input_idx = 0
  local output_idx = 0
  local queue = {}
  local set = {}
  return {
    -- Method appending a value to the queue if it doesn't exist in the queue:
    push = function(self, value)
      if not set[value] then
        queue[input_idx] = value
        set[value] = true
        input_idx = input_idx + 1
      end
    end,
    -- Method removing and returning the oldest value in the queue:
    pop = function(self)
      if output_idx == input_idx then
        return nil
      end
      local value = queue[output_idx]
      queue[output_idx] = nil
      set[value] = nil
      output_idx = output_idx + 1
      return value
    end,
    -- Method returning a value without removing it, skipping a certain count
    -- of values from the beginning (a skip_count of zero returns the very next
    -- value):
    peek = function(self, skip_count)
      return queue[output_idx + skip_count]
    end,
  }
end

-- fiber.yield is an alias for the yield effect represented by the "yield"
-- module:
_M.yield = yield

-- Helper function that throws an error due to missing fiber environment:
local function scope_error()
  return error("not running in fiber environment", 0)
end

-- Effect resuming with a handle of the currently running fiber, or nil if
-- called outside a scheduling environment:
local try_current = effect_new("fiber.try_current")
_M.try_current = try_current
effect_default_handlers[try_current] = function() return nil end

-- Function returning a handle of the currently running fiber:
local function current()
  local x = try_current()
  if x then
    return x
  end
  scope_error()
end
_M.current = current

-- Effect putting the currently running fiber to sleep:
local sleep = effect_new("fiber.sleep")
_M.sleep = sleep
effect_default_handlers[sleep] = scope_error

-- Effect killing the currently running fiber:
local suicide = effect_new("fiber.suicide")
_M.suicide = suicide
effect_default_handlers[suicide] = scope_error

-- spawn(action, ...) spawns a new fiber with the given action function and
-- arguments to the action function:
local spawn = effect_new("fiber.spawn")
_M.spawn = spawn
effect_default_handlers[spawn] = scope_error

-- Internal marker for attributes in the "fiber_methods" table:
local getter_magic = {}

-- Ephemeron storing fibers' attributes:
local fiber_attrs = setmetatable({}, { __mode = "k" })

-- Table containing all methods of fibers, plus public attributes where the
-- value in this table must be set to "getter_magic":
local fiber_methods = {
  -- table with return values of fiber's function or false if fiber was killed:
  results = getter_magic,
}

-- Method waking up the fiber (note that "self" is named "fiber" below):
function fiber_methods.wake(fiber)
  while fiber do
    local attrs = fiber_attrs[fiber]
    -- Add fiber to woken_fibers FIFO set:
    attrs.woken_fibers:push(fiber)
    -- Repeat procedure for all parent fibers:
    fiber = attrs.parent_fiber
  end
end

-- Method putting the currently executed fiber to sleep until being able to
-- return the given fiber's ("self"'s) results (prefixed by true as first
-- return value) or until the fiber has been killed (in which case false is
-- returned):
function fiber_methods.try_await(self)
  local attrs = fiber_attrs[self]
  local results = attrs.results
  -- Check if awaited fiber has been killed:
  if results == false then
    -- Awaited fiber has been killed.
    -- Return false to indicate fiber has been killed and there are no results:
    return false
  end
  -- Check if result is already available:
  if results then
    -- Result is already available.
    -- Return true with available results:
    return true, table_unpack(results, 1, results.n)
  end
  -- No result is available and awaited fiber has not been killed.
  -- Add currently executed fiber to other fiber's waiting list:
  table_insert(attrs.waiting_fibers, current())
  -- Sleep until result is available or awaited fiber has been killed and
  -- proceed same as above:
  while true do
    sleep()
    local results = attrs.results
    if results == false then
      return false
    end
    if results then
      return true, table_unpack(results, 1, results.n)
    end
  end
end

-- Same method as try_await but killing the current fiber if the awaited fiber
-- was killed (implemented redundantly for performance reasons):
function fiber_methods.await(self)
  local attrs = fiber_attrs[self]
  local results = attrs.results
  -- Check if awaited fiber has been killed:
  if results == false then
    -- Awaited fiber has been killed.
    -- Kill current fiber as well:
    return suicide()
  end
  -- Check if result is already available:
  if results then
    -- Result is already available.
    -- Return available results:
    return table_unpack(results, 1, results.n)
  end
  -- No result is available and awaited fiber has not been killed.
  -- Add currently executed fiber to other fiber's waiting list:
  table_insert(attrs.waiting_fibers, current())
  -- Sleep until result is available or awaited fiber has been killed and
  -- proceed same as above:
  while true do
    sleep()
    local results = attrs.results
    if results == false then
      return suicide()
    end
    if results then
      return table_unpack(results, 1, results.n)
    end
  end
end

-- Method killing the fiber, i.e. stopping its further execution:
function fiber_methods.kill(self)
  -- Check if killed fiber is current fiber:
  if self == try_current() then
    -- Killed fiber is currently running.
    -- Simply kill current fiber:
    return suicide()
  end
  -- Obtain attributes of fiber to kill:
  local attrs = fiber_attrs[self]
  -- Check if fiber has already terminated (with return value or killed):
  if attrs.results ~= nil then
    -- Fiber has already terminated; do nothing.
    return
  end
  -- Mark fiber as killed:
  attrs.results = false
  -- Obtain resume function (which must exist at this point):
  local resume = attrs.resume
  -- Check if resume function is a continuation:
  if attrs.started then
    -- "resume" is a continuation.
    -- Discontinue the continuation:
    resume:discontinue()
  end
  -- Ensure that fiber is not continued when woken or cleaned up:
  attrs.resume = nil
  -- Wakeup all fibers that are waiting for that fiber's return values:
  for i, waiting_fiber in ipairs(attrs.waiting_fibers) do
    waiting_fiber:wake()
  end
  -- Remove fiber from open_fibers table to immediately free resources (may
  -- still require yielding to remove fiber from woken_fibers):
  attrs.open_fibers[self] = nil
end

-- Metatable for fiber handles:
_M.fiber_metatbl = {
  __index = function(self, key)
    -- Lookup method or attribute magic:
    local value = fiber_methods[key]
    -- Check if key is a public attribute:
    if value == getter_magic then
      -- Key is an attribute.
      -- Obtain value from "fiber_attrs" ephemeron and return it:
      return fiber_attrs[self][key]
    end
    -- Key is not an attribute.
    -- Return method, if exists:
    return value
  end,
}

-- Function checking if there is any woken fiber:
function _M.pending()
  local fiber = try_current()
  while fiber do
    local attrs = fiber_attrs[fiber]
    local woken_fibers = attrs.woken_fibers
    -- Check first two positions in woken_fibers FIFO because first position
    -- could be a special (false) marker:
    if woken_fibers:peek(0) or woken_fibers:peek(1) then
      -- There is an entry in woken_fibers, which is not false,
      -- i.e. there is a woken fiber.
      return true
    end
    -- Repeat procedure for all parent fibers:
    fiber = attrs.parent_fiber
  end
  return false
end

-- Internal metatable for set of all open (not yet terminated) fibers within
-- the scheduler:
local open_fibers_metatbl = {
  -- Ensuring cleanup of all open fibers when set of open fibers is closed,
  -- e.g. due to a non-resumed effect or due to an error:
  __close = function(self)
    -- Iterate through all keys:
    for fiber in pairs(self) do
      local attrs = fiber_attrs[fiber]
      local resume = attrs.resume
      -- Check if resume function exists and whether it is a continuation:
      if resume and attrs.started then
        -- "resume" is a continuation.
        -- Discontinue the continuation:
        resume:discontinue()
        -- Note that it's not necessary to set attrs.resume to nil here,
        -- because when open_fibers is closed, there will be no scheduler
        -- anymore that would call the resume function. Moreover, the kill
        -- method will short-circuit if the fiber has already been killed and
        -- thus will also not use the resume function.
        --attrs.resume = nil
      end
      -- Check if results are missing:
      if attrs.results == nil then
        -- Fiber did not generate a return value and was not killed.
        -- Mark fiber as killed:
        attrs.results = false
      end
      -- Wakeup all fibers that are waiting for this fiber's return values:
      for i, waiting_fiber in ipairs(attrs.waiting_fibers) do
        waiting_fiber:wake()
      end
    end
  end,
}

-- scope(action, ...) runs the given "action" function with given arguments and
-- permits yielding/sleeping/spawning while it runs.
local function scope(...)
  -- Obtain parent fiber unless running as top-level scheduler:
  local parent_fiber = try_current()
  -- Remember all open fibers in a set with a cleanup handler:
  local open_fibers <close> = setmetatable({}, open_fibers_metatbl)
  -- FIFO set of woken fibers:
  local woken_fibers = fifoset()
  -- Local variable (used as upvalue) for currently running fiber:
  local current_fiber
  -- Forward declaration of spawn_impl function:
  local spawn_impl
  -- Effect handlers:
  local handlers = {
    -- Effect resuming with a handle of the currently running fiber:
    [try_current] = function(resume)
      -- Resume with handle of current fiber:
      return resume(current_fiber)
    end,
    -- Effect putting the currently running fiber to sleep:
    [sleep] = function(resume)
      -- Store continuation:
      fiber_attrs[current_fiber].resume = resume:persistent()
    end,
    -- Effect yielding execution to another (unspecified) fiber:
    [yield] = function(resume)
      -- Ensure that currently running fiber is woken again:
      woken_fibers:push(current_fiber)
      -- Store continuation:
      fiber_attrs[current_fiber].resume = resume:persistent()
    end,
    -- Effect invoked when current fiber is killed:
    [suicide] = function(resume)
      local attrs = fiber_attrs[current_fiber]
      -- Mark fiber as killed:
      attrs.results = false
      -- Mark fiber as closed (i.e. remove it from "open_fibers" table):
      open_fibers[current_fiber] = nil
      -- Wakeup all fibers that are waiting for this fiber's return values:
      for i, waiting_fiber in ipairs(attrs.waiting_fibers) do
        waiting_fiber:wake()
      end
    end,
    -- Effect spawning a new fiber:
    [spawn] = function(resume, ...)
      return resume:call(spawn_impl, ...)
    end,
  }
  -- Implementation of spawn function for current scheduler:
  function spawn_impl(func, ...)
    -- Create new fiber handle:
    local fiber = setmetatable({}, _M.fiber_metatbl)
    -- Create storage table for fiber's attributes:
    local attrs = {
      -- Store certain upvalues as private attributes:
      open_fibers = open_fibers,
      woken_fibers = woken_fibers,
      parent_fiber = parent_fiber,
      -- Sequence of other fibers waiting on the newly spawned fiber:
      waiting_fibers = {},
    }
    -- Store attribute table in ephemeron:
    fiber_attrs[fiber] = attrs
    -- Pack arguments to spawned fiber's function:
    local args = table_pack(...)
    -- Initialize resume function for first run:
    attrs.resume = function()
      -- Mark fiber as started, such that cleanup may take place later:
      attrs.started = true
      -- Run with effect handlers:
      return effect_handle(handlers, function()
        -- Run fiber's function and store its return values:
        attrs.results = table_pack(func(table_unpack(args, 1, args.n)))
        -- Mark fiber as closed (i.e. remove it from "open_fibers" table):
        open_fibers[current_fiber] = nil
        -- Wakeup all fibers that are waiting for this fiber's return values:
        for i, waiting_fiber in ipairs(attrs.waiting_fibers) do
          waiting_fiber:wake()
        end
      end)
    end
    -- Remember fiber as being open so it can be cleaned up later:
    open_fibers[fiber] = true
    -- Wakeup fiber for the first time (without waking parents because the
    -- fiber's scheduler and all parent schedulers if existent are currently
    -- running and will not sleep but only yield when there is a woken fiber):
    woken_fibers:push(fiber)
    -- Return fiber's handle:
    return fiber
  end
  -- Spawn main fiber:
  local main = spawn_impl(...)
  -- Unless running as top-level scheduler, include special marker (false) in
  -- "woken_fiber" FIFO to indicate that control has to be yielded to the
  -- parent scheduler:
  if parent_fiber then
    woken_fibers:push(false)
  end
  -- Main scheduling loop:
  while true do
    -- Check if main fiber has terminated:
    local main_results = fiber_attrs[main].results
    if main_results then
      -- Main fiber has terminated.
      -- Return results of main fiber:
      return table_unpack(main_results, 1, main_results.n)
    end
    -- Obtain next fiber to resume (or special marker):
    local fiber = woken_fibers:pop()
    -- Check if entry in "woken_fibers" was special marker (false) and if there
    -- are still fibers left:
      if fiber == false and next(open_fibers) then
      -- Special marker has been found and there are fibers left.
      -- Check if there is any other fiber to-be-woken without removing it from
      -- the FIFO:
      if woken_fibers:peek(0) then
        -- There is another fiber to-be-woken, so we only yield control to the
        -- parent scheduler (and do not sleep):
        yield()
      else
        -- All fibers are sleeping, so we sleep as well:
        sleep()
      end
      -- Re-insert special marker to yield control to the parent next time
      -- again:
      woken_fibers:push(false)
    else
      -- No special marker has been found or there are no fibers left.
      -- Check if there is no fiber to be woken and no parent:
      if not fiber then
        -- There is no woken fiber and no parent.
        -- Throw an exception:
        error("no running fiber remaining", 2)
      end
      -- Obtain resume function (if exists):
      local attrs = fiber_attrs[fiber]
      local resume = attrs.resume
      -- Check if resume function exists to avoid resuming after termination:
      if resume then
        -- Resume function exists.
        -- Remove resume function from fiber's attributes (avoids invocation
        -- when fiber has already terminated):
        attrs.resume = nil
        -- Set current_fiber:
        current_fiber = fiber
        -- Run resume function:
        resume()
      end
    end
  end
end
_M.scope = scope

-- handle(handlers, action, ...) acts like effect.handle(action, ...) but also
-- applies to spawned fibers within the action.
function _M.handle(handlers, ...)
  return effect_handle(handlers, scope, ...)
end

return _M
