-- The PLAIN Simple Authentication and Security Layer (SASL) Mechanism
-- https://datatracker.ietf.org/doc/html/rfc4616

-- NUL separates the fields of the initial response; a NUL inside a field
-- would silently change the meaning of the message.
local function check_no_nul(name, value)
    assert(not (value and value:find('\0', 1, true)), name .. ' must not contain NUL')
end

return function(authzid, authcid, password)
    -- Check before SASLprep, which takes C strings and would truncate at NUL
    check_no_nul('authzid', authzid)
    check_no_nul('authcid', authcid)
    check_no_nul('password', password)

    if mystringprep then
        authcid = mystringprep.stringprep(authcid, 'SASLprep')
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
        password = mystringprep.stringprep(password, 'SASLprep')
    end

    return coroutine.create(function()
        return (authzid or '') .. '\0' .. authcid .. '\0' .. password, true -- true for secret
    end)
end
