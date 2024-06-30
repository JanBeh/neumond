local effect = require "neumond.effect"
local wait_posix_fiber = require "neumond.wait.posix.fiber"
local pgeff = require "neumond.pgeff"

local function int_array_converter(s)
  local seq = {}
  for n in string.gmatch(s, "[0-9]+") do
    seq[#seq+1] = tonumber(n)
  end
  return seq
end

local point_metatbl = {}

local function point(x, y)
  return setmetatable({x = x, y = y}, point_metatbl)
end

local function input_converter(v)
  local mt = getmetatable(v)
  if mt == point_metatbl then
    return v.x .. "," ..v.y
  end
  return v
end

return effect.auto_traceback(wait_posix_fiber.main, function()
  local dbconn = assert(pgeff.connect(""))

  local a, b = 15, 7
  local result = dbconn:query("SELECT $1::INT + $2::INT AS val", a, b)
  assert(assert(result[1].val) == a + b)
  assert(type(result[1].val) == "number")
  assert(math.type(result[1].val) == "integer")
  assert(result.type_oid.val == 23) -- OID 23 is an INT4

  local result = dbconn:query("SELECT $1::INT", nil)
  assert(result[1][1] == nil)

  -- expect syntax error (error class "42"):
  local result, err = dbconn:query("SELEEEECT")
  assert(err.code and string.sub(err.code, 1, 2) == "42")

  pgeff.input_converter = input_converter
  dbconn.output_converters = {
    [1005] = int_array_converter, -- INT2[]'s OID is 1005
    [1007] = int_array_converter, -- INT4[]'s OID is 1007
    [1016] = int_array_converter, -- INT8[]'s OID is 1016
  }

  local result = dbconn:query(
    "SELECT $1::POINT <-> $2::POINT", point(1, 2), point(4, 6)
  )
  assert(result[1][1] == 5)

  local result = dbconn:query(
    "SELECT array_agg(x) FROM generate_series(11, 13) AS x"
  )
  local ary = result[1][1]
  assert(type(ary == "table"))
  assert(ary[1] == 11)
  assert(ary[2] == 12)
  assert(ary[3] == 13)
end)
