local effect = require "effect"
local fiber = require "fiber"
local waitio_fiber = require "waitio_fiber"
local eio = require "eio"
local scgi = require "scgi"
local web = require "web"

local scgi_path = assert(..., "no socket path given")

local function request_handler(conn, params)
  local body
  local body_len = assert(tonumber(params.CONTENT_LENGTH or 0))
  local body = assert(conn:read(body_len))
  assert(#body == body_len)
  print("NEW REQUEST:")
  for name, value in pairs(params) do
    print(name .. "=" .. value)
  end
  print("------------")
  local get_params = web.decode_urlencoded_form(params.QUERY_STRING or "")
  conn:write('Content-type: text/html\n\n')
  conn:write('<html><head><title>FastCGI demo</title></head><body>\n')
  if next(get_params) then
    conn:write('<p>The following GET parameters have been received:</p>\n')
    conn:write('<ul>\n')
    for key, value in pairs(get_params) do
      conn:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    conn:write('</ul>\n')
  else
  end
  if params.CONTENT_TYPE == "application/x-www-form-urlencoded" then
    local post_params = web.decode_urlencoded_form(body)
    conn:write('<p>The following POST parameters have been received:</p>\n')
    conn:write('<ul>\n')
    for key, value in pairs(post_params) do
      conn:write(
        '<li>', web.encode_html(key), ': ', web.encode_html(value), '</li>'
      )
    end
    conn:write('</ul>\n')
  end
  conn:write('<form method="POST">\n')
  conn:write('<input type="text" name="demokey">')
  conn:write('<input type="submit" value="Submit POST request">')
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
