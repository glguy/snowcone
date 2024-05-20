return function(authzid, authcid, key)
    if mystringprep then
        authcid = mystringprep.stringprep(authcid, 'SASLprep')
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
    end

    return coroutine.create(function()
        local first = authcid
        if authzid then
            first = first .. '\0' .. authzid
        end
        return key:sign(coroutine.yield(first))
    end)
end
