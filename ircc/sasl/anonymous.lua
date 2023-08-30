return function(trace)
    return coroutine.create(function()
        return trace
    end)
end
