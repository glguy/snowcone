local openssl = require 'openssl'

return function(authzid, authcid, key_txt, key_password)
    local key = assert(openssl.pkey.read(key_txt, true, 'auto', key_password))

    return coroutine.create(function()
        local first = authcid
        if authzid then
            first = first .. '\0' .. authzid
        end
        return key:sign(coroutine.yield(first))
    end)
end
