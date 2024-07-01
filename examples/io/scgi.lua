local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"
local scgi = require "neumond.scgi"
local web = require "neumond.web"

local scgi_path = assert(..., "no socket path given")

local function request_handler(req)
  req:process_request_body() -- start processing request body immediately
  print("NEW REQUEST:")
  for name, value in pairs(req.cgi_params) do
    print(name .. "=" .. value)
  end
  print("------------")
  req:write('Content-type: text/html\n\n')
  req:write('<html><head><title>SCGI demo</title></head><body>\n')
  if next(req.get_params) then
    req:write('<p>The following GET parameters have been received:</p>\n')
    req:write('<ul>\n')
    for key, value in pairs(req.get_params) do
      req:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    req:write('</ul>\n')
  else
  end
  if next(req.post_params) then
    req:write('<p>The following POST parameters have been received:</p>\n')
    req:write('<ul>\n')
    for key, value in pairs(req.post_params) do
      req:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    req:write('</ul>\n')
  end
  req:write('<form method="POST">\n')
  --req:write('<form method="POST" enctype="multipart/form-data">\n')
  req:write('<input type="text" name="demokey">\n')
  req:write('<input type="submit" value="Submit POST request">\n')
  req:write('</form>\n')
  req:write('</body></html>\n')
end

local terminate = effect.new("terminate")

print("Starting SCGI server.")

local function main(...)
  return fiber.handle(
    {
      [terminate] = function(resume, sig)
        print("Terminating SCGI server due to " .. sig .. ".")
      end
    },
    function()
      fiber.spawn(function() eio.catch_signal(2)(); terminate("SIGINT") end)
      fiber.spawn(function() eio.catch_signal(15)(); terminate("SIGTERM") end)
      scgi.run(scgi_path, request_handler)
    end
  )
end

runtime(main, ...)

print("SCGI server terminated.")
