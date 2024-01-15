_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local lkq = require "lkq"

local get_eventqueue = effect.new("waitio.get_eventqueue")

function _M.deregister_fd(fd)
  return get_eventqueue():deregister_fd(fd)
end

function _M.wait_fd_read(fd)
  local eventqueue = get_eventqueue()
  eventqueue:add_fd_read(fd, fiber.current())
  fiber.sleep()
  eventqueue:remove_fd_read(fd)
end

function _M.wait_fd_write(fd)
  local eventqueue = get_eventqueue()
  eventqueue:add_fd_write(fd, fiber.current())
  fiber.sleep()
  eventqueue:remove_fd_write(fd)
end

function _M.wait_signal(sig)
  -- TODO: race friendly API?
  local eventqueue = get_eventqueue()
  eventqueue:add_signal(sig, fiber.current())
  fiber.sleep()
  eventqueue:remove_signal(sig)
end

local function wake(self)
  return self:wake()
end

function _M.main(...)
  local eventqueue = lkq.new_queue()
  fiber.handle(
    {
      [get_eventqueue] = function(resume)
        return resume(eventqueue)
      end,
    },
    function(body, ...)
      fiber.spawn(function()
        while fiber.other() do
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

return _M
