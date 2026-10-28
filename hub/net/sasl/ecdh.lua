local check   = require 'hub.lib.check'
local sha256  = myopenssl.get_digest 'sha256'
local xor = myopenssl.xor

return function(authzid, authcid, client_seckey)
    -- NUL separates authcid from authzid in the initial response.
    -- Check before SASLprep, which takes C strings and would truncate at NUL.
    check(not authcid:find('\0', 1, true), 'authcid must not contain NUL')
    check(not (authzid and authzid:find('\0', 1, true)), 'authzid must not contain NUL')

    if mystringprep then
        authcid = mystringprep.stringprep(authcid, 'SASLprep')
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
    end

    return coroutine.create(function()
        local first = authcid
        if authzid then
            first = first ..'\0' .. authzid
        end
        local server_response = coroutine.yield(first)

        check(#server_response == 96, 'bad server response length')

        local server_pubkey_raw, session_salt, masked_challenge =
            string.sub(server_response, 1, 32),
            string.sub(server_response, 33, 64),
            string.sub(server_response, 65, 96)

        local server_pubkey = myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, false, server_pubkey_raw)
        local client_pubkey_raw = client_seckey:export().pub
        local shared_secret = client_seckey:derive(server_pubkey)

        -- ECDH_X25519_KDF()
        local ikm = sha256:digest(shared_secret .. client_pubkey_raw .. server_pubkey_raw)
        local prk = sha256:hmac(ikm, session_salt)
        local better_secret = sha256:hmac("ECDH-X25519-CHALLENGE\1", prk)

        return xor(masked_challenge, better_secret)
    end)
end
