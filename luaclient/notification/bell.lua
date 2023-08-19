return function()
    io.stdout:write '\x07' -- BELL control character
    io.stdout:flush()
end
