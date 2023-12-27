local pingpong = effect.new("pingpong")

local handlers1, handlers2

handlers1 = {
  [pingpong] = function(resume)
    print("ping")
    return effect.handle_once(handlers2, resume)
  end
}

handlers2 = {
  [pingpong] = function(resume)
    print("pong")
    return effect.handle_once(handlers1, resume)
  end
}

effect.handle_once(handlers1, function()
  while true do
    pingpong()
  end
end)
