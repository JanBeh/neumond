local fastcgi = require "fastcgi"
local web = require "web"

local fcgi_path = assert(..., "no socket path given")

print("Starting FastCGI server.")

fastcgi.main(fcgi_path, function(req)
  print("NEW REQUEST:")
  for name, value in pairs(req.params) do
    print(name .. "=" .. value)
  end
  print("------------")
  local get_params = web.decode_urlencoded_form(req.params.QUERY_STRING or "")
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
  if req.params.CONTENT_TYPE == "application/x-www-form-urlencoded" then
    req.stdin_waiter()
    local post_params = web.decode_urlencoded_form(req.stdin)
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
end)

print("FastCGI server terminated.")
