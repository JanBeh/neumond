_ENV = setmetatable({}, { __index = _G })
local _M = {}

local effect = require "effect"
local fiber = require "fiber"
local lkq = require "lkq"

_M.get_deregister_fd_func = effect.new("waitio.get_deregister_fd_func")
_M.get_wait_fd_read_func = effect.new("waitio.get_wait_fd_read_func")
_M.get_wait_fd_write_func = effect.new("waitio.get_wait_fd_write_func")
_M.get_wait_signal_func = effect.new("waitio.get_wait_fd_signal_func")

function _M.deregister_fd(fd)
  return _M.get_deregister_fd_func()(fd)
end

function _M.wait_fd_read(fd)
  return _M.get_wait_fd_read_func()(fd)
end

function _M.wait_fd_write(fd)
  return _M.get_wait_fd_write_func()(fd)
end

function _M.wait_signal(sig)
  return _M.get_wait_signal_func()(sig)
end

local function wake(self)
  return self:wake()
end

function _M.main(...)
  local eventqueue = lkq.new_queue()
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
  local function wait_signal(sig)
    -- TODO: race friendly API?
    eventqueue:add_signal(sig, fiber.current())
    fiber.sleep()
    eventqueue:remove_signal(sig)
  end
  fiber.handle(
    {
      [_M.get_deregister_fd_func] = function(resume)
        return resume(deregister_fd)
      end,
      [_M.get_wait_fd_read_func] = function(resume)
        return resume(wait_fd_read)
      end,
      [_M.get_wait_fd_write_func] = function(resume)
        return resume(wait_fd_write)
      end,
      [_M.get_wait_signal_func] = function(resume)
        return resume(wait_signal)
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
