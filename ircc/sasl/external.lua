-- https://datatracker.ietf.org/doc/html/rfc4422#appendix-A

return function(authzid)
    if mystringprep then
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
    end

    return coroutine.create(function()
        return authzid or ''
    end)
end
