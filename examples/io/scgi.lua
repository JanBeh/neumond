local effect = require "effect"
local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"
local scgi = require "scgi"
local web = require "web"

local scgi_path = assert(..., "no socket path given")

local function request_handler(req)
  local body = req:read()
  print("NEW REQUEST:")
  for name, value in pairs(req.cgi_params) do
    print(name .. "=" .. value)
  end
  print("------------")
  local get_params = web.decode_urlencoded_form(
    req.cgi_params.QUERY_STRING or ""
  )
  req:write('Content-type: text/html\n\n')
  req:write('<html><head><title>FastCGI demo</title></head><body>\n')
  if next(get_params) then
    req:write('<p>The following GET parameters have been received:</p>\n')
    req:write('<ul>\n')
    for key, value in pairs(get_params) do
      req:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    req:write('</ul>\n')
  else
  end
  if req.cgi_params.CONTENT_TYPE == "application/x-www-form-urlencoded" then
    local post_params = web.decode_urlencoded_form(body)
    req:write('<p>The following POST parameters have been received:</p>\n')
    req:write('<ul>\n')
    for key, value in pairs(post_params) do
      req:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    req:write('</ul>\n')
  end
  req:write('<form method="POST">\n')
  req:write('<input type="text" name="demokey">')
  req:write('<input type="submit" value="Submit POST request">')
end

local terminate = effect.new("terminate")

print("Starting SCGI server.")

effect.handle(
  {
    [terminate] = function(resume, sig)
      print("Terminating SCGI server due to " .. sig .. ".")
    end
  },
  waitio_fiber.main,
  function()
    fiber.spawn(function() eio.catch_signal(2)(); terminate("SIGINT") end)
    fiber.spawn(function() eio.catch_signal(15)(); terminate("SIGTERM") end)
    scgi.run(scgi_path, request_handler)
  end
)

print("SCGI server terminated.")
