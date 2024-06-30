local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local wait_posix_fiber = require "neumond.wait.posix.fiber"
local eio = require "neumond.eio"
local scgi = require "neumond.scgi"
local web = require "neumond.web"

local html = web.encode_html

local scgi_path = assert(..., "no socket path given")

local function request_handler(req)
  req:setup_stream("file",
    function(name)
      req:write('<p>File contents:</p>\n')
      req:write('<pre>');
    end,
    function(chunk)
      req:write(web.encode_html(chunk))
    end,
    function()
      req:write('</pre>\n')
    end
  )
  req:write('Content-type: text/html\n\n')
  req:write('<html><head><title>File upload demo</title></head><body>\n')
  req:await_stream() -- initiate and await processing of request body
  req:write('<p>Hidden field = ' .. html(req.post_params.key) .. '</p>\n')
  req:write('<p>File name = ' .. html(req.post_params_filename.file) .. '</p>\n')
  req:write('<p>Content type = ' .. html(req.post_params_content_type.file) .. '</p>\n')
  req:write('<form method="POST" enctype="multipart/form-data">\n')
  req:write('<input type="hidden" name="key" value="value1">\n')
  req:write('<input type="hidden" name="key" value="value2">\n')
  req:write('<input type="file" name="file">\n')
  req:write('<input type="submit">\n')
  req:write('</form>\n')
  req:write('</body></html>\n')
end

local terminate = effect.new("terminate")

print("Starting SCGI server.")

effect.handle(
  {
    [terminate] = function(resume, sig)
      print("Terminating SCGI server due to " .. sig .. ".")
    end
  },
  wait_posix_fiber.main,
  function()
    fiber.spawn(function() eio.catch_signal(2)(); terminate("SIGINT") end)
    fiber.spawn(function() eio.catch_signal(15)(); terminate("SIGTERM") end)
    scgi.run(scgi_path, request_handler)
  end
)

print("SCGI server terminated.")
