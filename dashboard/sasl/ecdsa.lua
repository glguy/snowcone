return function(authzid, authcid, key)
    -- NUL separates authcid from authzid in the initial response.
    -- Check before SASLprep, which takes C strings and would truncate at NUL.
    assert(not authcid:find('\0', 1, true), 'authcid must not contain NUL')
    assert(not (authzid and authzid:find('\0', 1, true)), 'authzid must not contain NUL')

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
