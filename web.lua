-- Support library for web applications

-- Disallow setting global variables in the implementation of this module:
_ENV = setmetatable({}, {
  __index = _G,
  __newindex = function() error("cannot set global variable", 2) end,
})

-- Table containing all public items of this module:
local _M = {}

function _M.encode_html(text)
  return (string.gsub(tostring(text), '[<>&"]', function(char)
    if char == '"' then return "&quot;"
    elseif char == '<' then return "&lt;"
    elseif char == '>' then return "&gt;"
    else return "&amp;" end
  end))
end

function _M.encode_uri(text)
  return (string.gsub(text, "[^0-9A-Za-z_%.~-]",
    function(char) return string.format("%%%02x", string.byte(char)) end
  ))
end

local decode_uri
do
  local b0, b9, bA, bF, ba, bf = string.byte("09AFaf", 1, 6)
  function decode_uri(str)
    return (string.gsub(
      string.gsub(str, "%+", " "),
      "%%([0-9A-Fa-f][0-9A-Fa-f])",
      function(hex)
        local n1, n2 = string.byte(hex, 1, 2)
        if n1 <= b9 then n1 = n1 - b0
        elseif n1 <= bF then n1 = n1 - bA + 10
        else n1 = n1 - ba + 10 end
        if n2 <= b9 then n2 = n2 - b0
        elseif n2 <= bF then n2 = n2 - bA + 10
        else n2 = n2 - ba + 10 end
        return string.char(n1 * 16 + n2)
      end
    ))
  end
end
_M.decode_uri = decode_uri

function _M.decode_urlencoded_form(str)
  local tbl = {}
  for key, value in string.gmatch(str, "([^&=]+)=([^&=]*)") do
    tbl[decode_uri(key)] = decode_uri(value)
  end
  return tbl
end

return _M
