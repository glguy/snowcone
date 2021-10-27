return function(authzid, authcid, password)
    return coroutine.create(function()
        return (authzid or '') .. '\0' .. authcid .. '\0' .. password
    end)
end
