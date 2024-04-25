-- Module for lightweight threads (fibers)

-- Import "effect" module:
local effect = require "effect"

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

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

-- Internally used effects (which are not exported) for
-- "current", "sleep", and "yield" functions:
local current = effect.new("fiber.current")
local sleep = effect.new("fiber.sleep")
local yield = effect.new("fiber.yield")

-- Function returning a handle of the currently running fiber:
_M.current = function()
  return current()
end

-- Function putting the currently running fiber to sleep:
_M.sleep = function()
  return sleep()
end

-- Function yielding execution to another (unspecified) fiber:
_M.yield = function()
  return yield()
end

-- Internally used effect when fiber terminates due to returning or being
-- killed:
local terminate = effect.new("fiber.terminate")

-- Internal marker for attributes in the "fiber_methods" table:
local getter_magic = {}

-- Ephemeron storing fibers' attributes:
local fiber_attrs = setmetatable({}, { __mode = "k" })

-- Table containing all methods of fibers, plus public attributes where the
-- value in this table must be set to "getter_magic":
local fiber_methods = {
  results = getter_magic, -- table with return values of fiber's function
  killed = getter_magic, -- true if fiber has been killed, e.g. by an effect
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
  -- Check if result is already available:
  local results = attrs.results
  if results then
    -- Result is already available.
    -- Return true with available results:
    return true, table.unpack(results, 1, results.n)
  end
  -- Result is not yet available.
  -- Check if awaited fiber has been killed:
  if attrs.killed then
    -- Awaited fiber has been killed.
    -- Return false to indicate fiber has been killed and there are no results:
    return false
  end
  -- No result is available and awaited fiber has not been killed.
  -- Add currently executed fiber to other fiber's waiting list:
  local waiting_fibers = attrs.waiting_fibers
  if waiting_fibers then
    waiting_fibers[#waiting_fibers+1] = current()
  else
    attrs.waiting_fibers = { current() }
  end
  -- Sleep until result is available or awaited fiber has been killed and
  -- proceed same as above:
  while true do
    sleep()
    local results = attrs.results
    if results then
      return true, table.unpack(results, 1, results.n)
    end
    if attrs.killed then
      return false
    end
  end
end

-- Same method as try_await but killing the current fiber if the awaited fiber
-- was killed (implemented redundantly for performance reasons):
function fiber_methods.await(self)
  local attrs = fiber_attrs[self]
  -- Check if result is already available:
  local results = attrs.results
  if results then
    -- Result is already available.
    -- Return available results:
    return table.unpack(results, 1, results.n)
  end
  -- Result is not yet available.
  -- Check if awaited fiber has been killed:
  if attrs.killed then
    -- Awaited fiber has been killed.
    -- Kill current fiber as well:
    fiber_attrs[current()].killed = true
    return terminate()
  end
  -- No result is available and awaited fiber has not been killed.
  -- Add currently executed fiber to other fiber's waiting list:
  local waiting_fibers = attrs.waiting_fibers
  if waiting_fibers then
    waiting_fibers[#waiting_fibers+1] = current()
  else
    attrs.waiting_fibers = { current() }
  end
  -- Sleep until result is available or awaited fiber has been killed and
  -- proceed same as above:
  while true do
    sleep()
    local results = attrs.results
    if results then
      return table.unpack(results, 1, results.n)
    end
    if attrs.killed then
      fiber_attrs[current()].killed = true
      return terminate()
    end
  end
end

-- Method killing the fiber, i.e. stopping its further execution:
function fiber_methods.kill(self)
  local attrs = fiber_attrs[self]
  -- Check if fiber has already terminated (with return value or killed):
  if attrs.results or attrs.killed then
    -- Fiber is already killed.
    -- Do nothing.
    return
  end
  -- Mark fiber as killed:
  attrs.killed = true
  -- Check if killed fiber is current fiber:
  if self == current() then
    -- Killed fiber is currently running.
    -- Simply terminate currently running fiber (already marked as killed):
    return terminate()
  end
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
  local waiting_fibers = attrs.waiting_fibers
  if waiting_fibers then
    for i, waiting_fiber in ipairs(waiting_fibers) do
      waiting_fiber:wake()
    end
  end
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

-- spawn(action, ...) spawns a new fiber with the given action function and
-- arguments to the action function:
function _M.spawn(...)
  -- Use spawn function of current fiber:
  return fiber_attrs[current()].spawn(...)
end

-- Function checking if there is any woken fiber:
function _M.pending()
  local fiber = current()
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
        -- method will short-circuit when the killed attribute is true and thus
        -- also not call the resume function.
        --attrs.resume = nil
      end
      -- Check if results are missing:
      if not attrs.results then
        -- Fiber did not generate a return value.
        -- Mark fiber as killed:
        attrs.killed = true
      end
      -- Wakeup all fibers that are waiting for this fiber's return values:
      local waiting_fibers = attrs.waiting_fibers
      if waiting_fibers then
        for i, waiting_fiber in ipairs(waiting_fibers) do
          waiting_fiber:wake()
        end
      end
    end
  end,
}

-- Implementation for top-level scheduling (used by module's "main" function,
-- with argument "nested" set to false) and sub-level scheduling (used by
-- module's "scope" function, with argument "nested" set to true):
local function schedule(nested, ...)
  -- Obtain parent fiber unless running as top-level scheduler:
  local parent_fiber
  if nested then
    parent_fiber = current()
  end
  -- Remember all open fibers in a set with a cleanup handler:
  local open_fibers <close> = setmetatable({}, open_fibers_metatbl)
  -- FIFO set of woken fibers:
  local woken_fibers = fifoset()
  -- Local variable (used as upvalue) for currently running fiber:
  local current_fiber
  -- Effect handlers:
  local handlers = {
    -- Effect resuming with a handle of the currently running fiber:
    [current] = function(resume)
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
    -- Effect invoked when fiber has terminated:
    [terminate] = function(resume)
      -- Note that this effect must not be invoked unless a result (return
      -- values) has been stored or the fiber has been marked as being killed.
      -- Mark fiber as closed (i.e. remove it from "open_fibers" table):
      open_fibers[current_fiber] = nil
      -- Wakeup all fibers that are waiting for this fiber's return values:
      local waiting_fibers = fiber_attrs[current_fiber].waiting_fibers
      if waiting_fibers then
        for i, waiting_fiber in ipairs(waiting_fibers) do
          waiting_fiber:wake()
        end
      end
    end
  }
  -- Implementation of spawn function for current scheduler:
  local function spawn(func, ...)
    -- Create new fiber handle:
    local fiber = setmetatable({}, _M.fiber_metatbl)
    -- Create storage table for fiber's attributes:
    local attrs = {
      -- Store certain upvalues as private attributes:
      open_fibers = open_fibers,
      woken_fibers = woken_fibers,
      spawn = spawn,
      parent_fiber = parent_fiber,
      -- Initialize "killed" attribute to false:
      killed = false,
    }
    -- Store attribute table in ephemeron:
    fiber_attrs[fiber] = attrs
    -- Pack arguments to spawned fiber's function:
    local args = table.pack(...)
    -- Initialize resume function for first run:
    attrs.resume = function()
      -- Mark fiber as started, such that cleanup may take place later:
      attrs.started = true
      -- Run with effect handlers:
      return effect.handle(handlers, function()
        -- Run fiber's function and store its return values:
        attrs.results = table.pack(func(table.unpack(args, 1, args.n)))
        -- Terminate fiber through effect:
        return terminate()
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
  local main = spawn(...)
  -- Unless running as top-level scheduler, include special marker (false) in
  -- "woken_fiber" FIFO to indicate that control has to be yielded to the
  -- parent scheduler:
  if nested then
    woken_fibers:push(false)
  end
  -- Main scheduling loop:
  while true do
    -- Check if main fiber has terminated:
    local main_results = fiber_attrs[main].results
    if main_results then
      -- Main fiber has terminated.
      -- Return results of main fiber:
      return table.unpack(main_results, 1, main_results.n)
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
        error("fibers are deadlocked", 2)
      end
      -- Obtain resume function (if exists):
      local attrs = fiber_attrs[fiber]
      local resume = attrs.resume
      -- Check if resume function exists to avoid resuming after termination:
      if resume then
        -- Resume function exists.
        -- Remove resume function from fiber's attributes (avoids invocation when
        -- fiber has already terminated):
        attrs.resume = nil
        -- Set current_fiber:
        current_fiber = fiber
        -- Run resume function:
        resume()
      end
    end
  end
end

-- main(action, ...) runs the given "action" function with given arguments as
-- main fiber and permits yielding/sleeping/spawning while it runs.
function _M.main(...)
  return schedule(false, ...)
end

-- scope(action, ...) runs the given "action" function with given arguments and
-- handles spawning. It does not return until all spawned fibers have
-- terminated.
function _M.scope(...)
  return schedule(true, ...)
end

-- handle(handlers, action, ...) acts like effect.handle(action, ...) but also
-- applies to spawned fibers within the action.
function _M.handle(handlers, ...)
  return effect.handle(handlers, schedule, true, ...)
end

return _M
