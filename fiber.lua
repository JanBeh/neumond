local effect = require "effect"

_ENV = setmetatable({}, {
  __index    = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

local _M = {}

local function fifoset()
  local input_idx = 0
  local output_idx = 0
  local queue = {}
  local set = {}
  return {
    push = function(self, value)
      if not set[value] then
        queue[input_idx] = value
        input_idx = input_idx + 1
        set[value] = true
      end
    end,
    pop = function(self)
      if output_idx ~= input_idx then
        local value = queue[output_idx]
        output_idx = output_idx + 1
        set[value] = nil
        return value
      else
        return nil
      end
    end,
  }
end

local get_current = effect.new("current")
local sleep = effect.new("sleep")
local yield = effect.new("yield")

_M.current = function()
  return get_current()
end
_M.sleep = function()
  return sleep()
end
_M.yield = function()
  return yield()
end

local getter_magic = {}
local fiber_attrs = setmetatable({}, { __mode = "k" })

local fiber_meths = {
  results = getter_magic,
}

local function wake(fiber)
  -- Code for (future) nested scheduling:
  --while fiber do
  --  local attrs = fiber_attrs[fiber]
  --  attrs.woken_fibers:push(fiber)
  --  fiber = attrs.parent_fiber
  --end
  fiber_attrs[fiber].woken_fibers:push(fiber)
end

function fiber_meths.wake(self)
  return wake(self)
end

function fiber_meths.await(self)
  local attrs = fiber_attrs[self]
  local results = attrs.results
  if results then
    return table.unpack(results, 1, results.n)
  end
  local waiting_fibers = attrs.waiting_fibers
  if not waiting_fibers then
    waiting_fibers = fifoset()
    attrs.waiting_fibers = waiting_fibers
  end
  waiting_fibers:push(get_current())
  while true do
    sleep()
    local results = attrs.results
    if results then
      return table.unpack(results, 1, results.n)
    end
  end
end

_M.fiber_metatbl = {
  __index = function(self, key)
    local value = fiber_meths[key]
    if value == getter_magic then
      return fiber_attrs[self][key]
    else
      return value
    end
  end,
}

function _M.spawn(...)
  return fiber_attrs[get_current()].spawn(...)
end

local fibers_metatbl = {
  __close = function(self)
    for fiber in pairs(self) do
      local attrs = fiber_attrs[fiber]
      local resume = attrs.resume
      if resume and attrs.started then
        effect.discontinue(resume)
      end
    end
  end,
}

function _M.main(...)
  local fibers <close> = setmetatable({}, fibers_metatbl)
  local woken_fibers = fifoset()
  local current_fiber
  local resume_scheduled
  local handlers
  handlers = {
    [get_current] = function(resume)
      return effect.handle_once(handlers, resume, current_fiber)
    end,
    [sleep] = function(resume)
      fiber_attrs[current_fiber].resume = resume
      return resume_scheduled()
    end,
    [yield] = function(resume)
      wake(current_fiber)
      fiber_attrs[current_fiber].resume = resume
      return resume_scheduled()
    end,
  }
  local function spawn(func, ...)
    local fiber = setmetatable({}, _M.fiber_metatbl)
    local attrs = {}
    fiber_attrs[fiber] = attrs
    local args = table.pack(...)
    attrs.resume = function()
      attrs.started = true
      return table.pack(func(table.unpack(args, 1, args.n)))
    end
    attrs.woken_fibers = woken_fibers
    attrs.spawn = spawn
    fibers[fiber] = true
    woken_fibers:push(fiber)
    return fiber
  end
  local main = spawn(...)
  resume_scheduled = function()
    local fiber = woken_fibers:pop()
    if fiber == nil then
      local results = main.results
      if results then
        return table.unpack(results, 1, results.n)
      end
      error("main fiber did not terminate", 0)
    end
    local attrs = fiber_attrs[fiber]
    local resume = attrs.resume
    if resume then
      attrs.resume = nil
      current_fiber = fiber
      attrs.results = effect.handle_once(handlers, resume)
      fibers[fiber] = nil
      local waiting_fibers = attrs.waiting_fibers
      if waiting_fibers then
        while true do
          local waiting_fiber = waiting_fibers:pop()
          if not waiting_fiber then
            break
          end
          wake(waiting_fiber)
        end
      end
    end
    return resume_scheduled()
  end
  return resume_scheduled()
end

return _M
