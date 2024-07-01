local expected = 1

local function checkpoint(x, ...)
  if x == expected then
    expected = expected + 1
  elseif ... == nil then
    error("expected checkpoint " .. expected, 2)
  else
    return checkpoint(...)
  end
end

return checkpoint
