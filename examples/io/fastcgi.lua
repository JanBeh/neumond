local fastcgi = require "fastcgi"

local fcgi_path = assert(..., "no socket path given")

print("Starting FastCGI server.")

fastcgi.main(fcgi_path, function(req)
  print("NEW REQUEST:")
  for name, value in pairs(req.params) do
    print(name .. "=" .. value)
  end
  print("------------")
  req:write("Content-type: text/plain\n\n")
  req:write("Hello World!\n")
  req:flush()
end)

print("FastCGI server terminated.")
