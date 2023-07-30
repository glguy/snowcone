return function(authzid)
    return coroutine.create(function()
        return authzid or ''
    end)
end
