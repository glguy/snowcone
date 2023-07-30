return function(authzid, authcid, key)
    return coroutine.create(function()
        local first = authcid
        if authzid then
            first = first .. '\0' .. authzid
        end
        return key:sign(coroutine.yield(first))
    end)
end
