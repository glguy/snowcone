-- The PLAIN Simple Authentication and Security Layer (SASL) Mechanism
-- https://datatracker.ietf.org/doc/html/rfc4616

return function(authzid, authcid, password)
    if mystringprep then
        authcid = mystringprep.stringprep(authcid, 'SASLprep')
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
        password = mystringprep.stringprep(password, 'SASLprep')
    end

    return coroutine.create(function()
        return (authzid or '') .. '\0' .. authcid .. '\0' .. password, true -- true for secret
    end)
end
