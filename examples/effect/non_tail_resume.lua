local effect = require "neumond.effect"

local collect = effect.new("collect")
local use = effect.new("use")

local t = {}

local retval = effect.handle(
  {
    [collect] = function(resume, element)
      local count = #t + 1
      t[count] = element
      return resume()
    end,
    [use] = function(resume)
      local retval = table.concat(t, ",")
      resume()
      return retval
    end,
  },
  function(last)
    local check
    for i = 1, 10 do
      collect(tostring(i))
      if i == last then
        use()
      end
      check = i
    end
    assert(check == 10)
  end,
  7
)

assert(retval == "1,2,3,4,5,6,7")
