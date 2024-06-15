local wait_posix = require "wait_posix"
local wait_posix_blocking = require "wait_posix_blocking"

wait_posix_blocking.main(
  function()
    while true do
      print("reader waiting")
      wait_posix.wait_fd_read(0)
      print("reader woken")
      print("read: " .. assert(io.stdin:read()))
    end
  end
)
