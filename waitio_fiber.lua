_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local waitio = require "waitio"
local lkq = require "lkq"

local catcher_metatbl = {
  __call = function(self)
    while not self.triggered do
      if self.fiber then
        error("catcher already in use", 2)
      end
      self.fiber = fiber.current()
      fiber.sleep()
      self.fiber = nil
    end
    self.triggered = false
  end,
}

local function wake(self)
  return self:wake()
end

local weak_mt = { __mode = "k" }

function _M.run(...)
  local eventqueue <close> = lkq.new_queue()
  local signal_catchers = {}
  local signal_fibers <close> = setmetatable({}, {
    __close = function(self)
      for sig, signal_fiber in pairs(self) do
        signal_fiber:kill()
      end
    end,
  })
  local function deregister_fd(fd)
    eventqueue:deregister_fd(fd)
  end
  local function wait_fd_read(fd)
    eventqueue:add_fd_read(fd, fiber.current())
    fiber.sleep()
    eventqueue:remove_fd_read(fd)
  end
  local function wait_fd_write(fd)
    eventqueue:add_fd_write(fd, fiber.current())
    fiber.sleep()
    eventqueue:remove_fd_write(fd)
  end
  local function catch_signal(sig)
    local signal_fiber = signal_fibers[sig]
    if not signal_fiber then
      local parent = fiber.current()
      signal_fiber = fiber.spawn(function()
        parent:wake()
        while true do
          fiber.sleep()
          for catcher in pairs(signal_catchers[sig]) do
            catcher.triggered = true
            local catcher_fiber = catcher.fiber
            if catcher_fiber then
              catcher_fiber:wake()
            end
          end
        end
      end)
      signal_fibers[sig] = signal_fiber
      fiber.sleep()
      eventqueue:add_signal(sig, signal_fiber)
    end
    local catcher = setmetatable({triggered = false}, catcher_metatbl)
    local catchers = signal_catchers[sig]
    if catchers then
      catchers[catcher] = true
    else
      catchers = setmetatable({[catcher] = true}, weak_mt)
      signal_catchers[sig] = catchers
    end
    return catcher
  end
  fiber.handle(
    {
      [waitio.deregister_fd] = function(resume, fd)
        return resume(effect.autocall, deregister_fd, fd)
      end,
      [waitio.wait_fd_read] = function(resume, fd)
        return resume(effect.autocall, wait_fd_read, fd)
      end,
      [waitio.wait_fd_write] = function(resume, fd)
        return resume(effect.autocall, wait_fd_write, fd)
      end,
      [waitio.catch_signal] = function(resume, sig)
        return resume(effect.autocall, catch_signal, sig)
      end,
    },
    function(body, ...)
      fiber.spawn(function()
        while true do
          if fiber.pending() then
            eventqueue:poll(wake)
          else
            eventqueue:wait(wake)
          end
          fiber.yield()
        end
      end)
      return body(...)
    end,
    ...
  )
end

function _M.main(...)
  return fiber.main(
    _M.run,
    ...
  )
end

return _M