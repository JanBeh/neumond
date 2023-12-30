-- Lightweight threads (fibers)

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
    push = function(self, value)
      if not set[value] then
        queue[input_idx] = value
        set[value] = true
        input_idx = input_idx + 1
      end
    end,
    pop = function(self)
      if output_idx ~= input_idx then
        local value = queue[output_idx]
        queue[output_idx] = nil
        set[value] = nil
        output_idx = output_idx + 1
        return value
      else
        return nil
      end
    end,
  }
end

-- Internally used effects (which are not exported) for
-- "current", "sleep", and "yield" functions:
local get_current = effect.new("current")
local sleep = effect.new("sleep")
local yield = effect.new("yield")

-- Function returning a handle of the currently running fiber:
_M.current = function()
  return get_current()
end

-- Function putting the currently running fiber to sleep:
_M.sleep = function()
  return sleep()
end

-- Function yielding execution to another (unspecified) fiber:
_M.yield = function()
  return yield()
end

-- Internal marker for attributes in the "fiber_meths" table:
local getter_magic = {}

-- Ephemeron storing fibers' attributes:
local fiber_attrs = setmetatable({}, { __mode = "k" })

-- Table containing all methods of fibers, plus public attributes where the
-- value in this table must be set to "getter_magic":
local fiber_meths = {
  results = getter_magic,
}

-- Method waking up the fiber (note that "self" is named "fiber" below):
function fiber_meths.wake(fiber)
  while fiber do
    local attrs = fiber_attrs[fiber]
    attrs.woken_fibers:push(fiber)
    -- Repeat procedure for all parent fibers:
    fiber = attrs.parent_fiber
  end
end

-- Method putting the currently executed fiber to sleep until being able to
-- return the given fiber's ("self"'s) result:
function fiber_meths.await(self)
  -- Try first if result is already available:
  local attrs = fiber_attrs[self]
  local results = attrs.results
  if results then
    return table.unpack(results, 1, results.n)
  end
  -- Add currently executed fiber to other fiber's waiting list:
  local waiting_fibers = attrs.waiting_fibers
  if not waiting_fibers then
    waiting_fibers = fifoset()
    attrs.waiting_fibers = waiting_fibers
  end
  waiting_fibers:push(get_current())
  -- Sleep until result is available:
  while true do
    sleep()
    local results = attrs.results
    if results then
      return table.unpack(results, 1, results.n)
    end
  end
end

-- Metatable for fiber handles:
_M.fiber_metatbl = {
  __index = function(self, key)
    -- Lookup method or attribute magic:
    local value = fiber_meths[key]
    -- Check if key is a public attribute:
    if value == getter_magic then
      -- Key is an attribute.
      -- Obtain value from "fiber_attrs" ephemeron and return it:
      return fiber_attrs[self][key]
    else
      -- Key is not an attribute.
      -- Return method, if exists:
      return value
    end
  end,
}

-- spawn(action, ...) spawns a new fiber with the given action function and
-- arguments to the action function:
function _M.spawn(...)
  return fiber_attrs[get_current()].spawn(...)
end

-- Internal metatable for set of all open (unfinished) fibers:
local open_fibers_metatbl = {
  -- Ensuring cleanup of all open fibers:
  __close = function(self)
    -- Iterate through all keys:
    for fiber in pairs(self) do
      local attrs = fiber_attrs[fiber]
      local resume = attrs.resume
      -- Check if resume function exists and whether it is a continuation:
      if resume and attrs.started then
        -- "resume" is a continuation.
        -- Discontinue the continuation:
        effect.discontinue(resume)
      end
    end
  end,
}

-- Implementation for module's "main" and "handle" functions:
local function schedule(nested, ...)
  -- Obtain parent fiber if applicable:
  local parent_fiber
  if nested then
    parent_fiber = get_current()
  end
  -- Remember all open fibers for later cleanup:
  local open_fibers <close> = setmetatable({}, open_fibers_metatbl)
  -- FIFO set of woken fibers:
  local woken_fibers = fifoset()
  -- Local variable (used as upvalue) for currently running fiber:
  local current_fiber
  -- Function running main loop (with tail-recursion), defined later:
  local resume_scheduled
  -- Declare handlers table because entries need to refer to handlers table:
  local handlers
  -- Define handlers table:
  handlers = {
    -- Effect resuming with a handle of the currently running fiber:
    [get_current] = function(resume)
      -- Re-install handler on resuming with current fiber:
      return effect.handle_once(handlers, resume, current_fiber)
    end,
    -- Effect putting the currently running fiber to sleep:
    [sleep] = function(resume)
      -- Store continuation:
      fiber_attrs[current_fiber].resume = resume
      -- Jump to main loop:
      return resume_scheduled()
    end,
    -- Effect yielding execution to another (unspecified) fiber:
    [yield] = function(resume)
      -- Ensure that currently running fiber is woken again:
      woken_fibers:push(current_fiber)
      -- Store continuation:
      fiber_attrs[current_fiber].resume = resume
      -- Jump to main loop:
      return resume_scheduled()
    end,
  }
  -- Implementation of spawn function for current scheduler:
  local function spawn(func, ...)
    -- Create new fiber handle:
    local fiber = setmetatable({}, _M.fiber_metatbl)
    -- Create storage table for attributes in ephemeron:
    local attrs = {}
    fiber_attrs[fiber] = attrs
    -- Pack arguments to spawned fiber's function:
    local args = table.pack(...)
    -- Initialize resume function for first run:
    attrs.resume = function()
      -- Mark fiber as started, such that cleanup may take place later:
      attrs.started = true
      -- Run fiber's function and store its return values:
      attrs.results = table.pack(func(table.unpack(args, 1, args.n)))
      -- Mark fiber as closed (i.e. remove it from "open_fibers" table):
      open_fibers[fiber] = nil
      -- Wakeup all fibers that are waiting for this fiber's return values:
      local waiting_fibers = attrs.waiting_fibers
      if waiting_fibers then
        while true do
          local waiting_fiber = waiting_fibers:pop()
          if not waiting_fiber then
            break
          end
          waiting_fiber:wake()
        end
      end
    end
    -- Store certain upvalues as private attributes:
    attrs.woken_fibers = woken_fibers
    attrs.spawn = spawn
    attrs.parent_fiber = parent_fiber
    -- Remember fiber as being open so it can be cleaned up later:
    open_fibers[fiber] = true
    -- Wakeup fiber for the first time (no need to wake parents):
    woken_fibers:push(fiber)
    -- Return fiber's handle:
    return fiber
  end
  -- Spawn main fiber:
  local main = spawn(...)
  -- Include special marker (false) in "woken_fiber" FIFO to indicate that
  -- control has to be yielded to the parent scheduler:
  if nested then
    woken_fibers:push(false)
  end
  -- Main scheduling loop (using tail-recursion):
  resume_scheduled = function()
    -- Obtain next fiber to resume (or special marker):
    local fiber = woken_fibers:pop()
    -- Check if entry in "woken_fibers" was special marker (false) and if there
    -- are still fibers left:
    if fiber == false and next(open_fibers) then
      -- Special marker has been found and there are fibers left.
      -- Check if there is any other fiber to-be-woken and obtain that fiber:
      fiber = woken_fibers:pop()
      if fiber then
        -- There is another to-be-woken, so we only yield control to the parent
        -- scheduler (and do not sleep):
        yield()
        -- Re-insert special marker to yield control to the parent next time
        -- again:
        woken_fibers:push(false)
        -- Do not return here, but use obtained woken fiber further below.
      else
        -- All fibers are sleeping, so we sleep as well:
        sleep()
        -- Re-insert special marker to yield control to the parent next time
        -- again:
        woken_fibers:push(false)
        -- Jump to beginning of main loop:
        return resume_scheduled()
      end
    end
    -- Check if there is no fiber to be woken and no parent:
    if not fiber then
      -- There is no woken fiber and no parent.
      -- Check if main fiber has returned:
      local results = main.results
      if results then
        -- Main fiber has returned.
        -- Return return values of main fiber:
        return table.unpack(results, 1, results.n)
      end
      -- Main fiber has not returned, thus there is a deadlock.
      -- Throw an exception:
      error("main fiber did not terminate", 0)
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
      -- Run resume function with effect handling:
      effect.handle_once(handlers, resume)
    end
    -- Repeat main loop:
    return resume_scheduled()
  end
  -- Start main loop:
  return resume_scheduled()
end

-- main(action, ...) runs the given "action" function with given arguments as
-- main fiber and permits yielding/sleeping/spawning while it runs.
function _M.main(...)
  return schedule(false, ...)
end

-- handle(action, ...) acts like effect.handle(action, ...) but also applies to
-- the spawned fibers:
function _M.handle(handlers, ...)
  return effect.handle(handlers, schedule, true, ...)
end

return _M
