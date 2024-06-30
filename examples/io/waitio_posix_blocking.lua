local wait = require "neumond.wait"
local wait_posix = require "neumond.wait.posix"
local wait_posix_blocking = require "neumond.wait.posix.blocking"

wait_posix_blocking.main(function()
  print("Startup")
  local sigint_count = 0
  local sigint = wait_posix.catch_signal(2)
  local sigterm = wait_posix.catch_signal(15)
  local timeout = wait.timeout(30)
  wait.timeout(1)()
  local interval = wait.interval(2)
  while true do
    print("Main loop")
    wait.select(
      "handle", sigint,
      "handle", sigterm,
      "handle", interval,
      "handle", timeout
    )
    if sigint.ready then
      print("SIGINT caught")
      sigint_count = sigint_count + 1
      if sigint_count == 1 then
        print("Two more SIGINTs needed")
      elseif sigint_count == 2 then
        print("One more SIGINT needed")
      elseif sigint_count >= 3 then
        break
      end
      sigint.ready = false
    end
    if sigterm.ready then
      print("SIGTERM caught")
      break
    end
    if interval.ready then
      print("Tick")
      interval.ready = false
    end
    if timeout.ready then
      print("Timeout")
      break
    end
  end
end)
