local sha256  = myopenssl.get_digest 'sha256'

return function(authzid, authcid, client_seckey)
    return coroutine.create(function()
        local first = authcid
        if authzid then
            first = first ..'\0' .. authzid
        end
        local server_response = coroutine.yield(first)

        assert(#server_response == 96)

        local server_pubkey_raw, session_salt, masked_challenge =
            string.sub(server_response, 1, 32),
            string.sub(server_response, 33, 64),
            string.sub(server_response, 65, 96)

        local server_pubkey = assert(myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, false, server_pubkey_raw))
        local client_pubkey_raw = client_seckey:get_raw_public()
        local shared_secret = assert(client_seckey:derive(server_pubkey))

        -- ECDH_X25519_KDF()
        local ikm = sha256:digest(shared_secret .. client_pubkey_raw .. server_pubkey_raw)
        local prk = sha256:hmac(ikm, session_salt)
        local better_secret = sha256:hmac("ECDH-X25519-CHALLENGE\1", prk)

        return snowcone.xor_strings(masked_challenge, better_secret)
    end)
end
