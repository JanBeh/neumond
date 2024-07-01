local effect = require "neumond.effect"
local fiber = require "neumond.fiber"
local runtime = require "neumond.runtime"
local eio = require "neumond.eio"
local scgi = require "neumond.scgi"
local web = require "neumond.web"
local pgeff = require "neumond.pgeff"

local scgi_path = assert(..., "no socket path given")

local function request_handler(req)
  req:process_request_body()
  local dbconn = assert(pgeff.connect("dbname=demoapplication"))
  local result = assert(dbconn:query([[
CREATE TABLE IF NOT EXISTS account (
  id SERIAL8 PRIMARY KEY,
  name TEXT NOT NULL );]]));
  if req.post_params.action == "add" then
    local result = assert(dbconn:query(
      "INSERT INTO account (name) VALUES ($1)", req.post_params.name
    ))
  end
  if req.post_params.action == "delete" then
    for key, value in pairs(req.post_params) do
      local id = tonumber((string.match(key, "^id([0-9]+)$")))
      if id then
        local result = assert(
          dbconn:query("DELETE FROM account WHERE id=$1", id)
        )
      end
    end
  end
  local result = assert(
    dbconn:query("SELECT * FROM account ORDER BY name, id")
  )
  req:write("Content-type: text/html\n\n")
  req:write('<html><head><title>demoapplication</title></head><body>\n')
  req:write('<h1>Accounts</h1>\n')
  req:write('<form method="POST">\n')
  req:write('<input type="hidden" name="action" value="delete">\n')
  req:write('<ul>\n')
  if result[1] then
    for idx, entry in ipairs(result) do
      req:write(
        '<li>',
        web.encode_html(entry.name),
        ' (',
        web.encode_html(entry.id),
        ') ',
        '<input type="submit" name="id', web.encode_html(entry.id), '"',
        ' value="Delete">',
        '</form></li>\n'
      )
    end
  else
    req:write('<li><i>(none)</i></li>\n')
  end
  req:write('</ul></form>\n')
  req:write('<form method="POST">\n')
  req:write('<input type="hidden" name="action" value="add">\n')
  req:write('<label for="name">New account name:</label>\n')
  req:write('<input name="name">\n')
  req:write('<input type="submit" value="Save">\n')
  req:write('</form>\n')
  req:write("</body></html>\n")
end

local terminate = effect.new("terminate")

return runtime(
  fiber.handle,
  { [terminate] = function(resume, sig) end },
  function()
    fiber.spawn(function() eio.catch_signal(2)(); terminate() end)
    fiber.spawn(function() eio.catch_signal(15)(); terminate() end)
    scgi.run(scgi_path, request_handler)
  end
)
