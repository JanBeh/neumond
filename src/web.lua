-- Support library for web applications

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

local tostring = tostring
local gsub = string.gsub
local format = string.format
local byte = string.byte

local function replaced_html_char(char)
  if char == '"' then return "&quot;"
  elseif char == '<' then return "&lt;"
  elseif char == '>' then return "&gt;"
  else return "&amp;" end
end

function _M.encode_html(text)
  return (gsub(tostring(text), '[<>&"]', replaced_html_char))
end

function _M.encode_uri(text)
  return (gsub(text, "[^0-9A-Za-z_%.~-]",
    function(char) return format("%%%02x", byte(char)) end
  ))
end

return _M
