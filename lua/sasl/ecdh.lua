
local function x25519_to_raw(pubkey)
    return string.sub(pubkey:export('der'), 13, 44)
end

local function raw_to_x25519(raw)
    local openssl = require 'openssl'
    return openssl.pkey.read(
        "\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00" .. raw,
        false, 'der')
end

return function(authzid, authcid, key_txt, key_password)
    local openssl = require 'openssl'
    local sha256  = openssl.digest.get 'sha256'

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

        local server_pubkey = raw_to_x25519(server_pubkey_raw)
        local client_seckey = assert(openssl.pkey.read(key_txt, true, 'auto', key_password))
        local client_pubkey = client_seckey:get_public()
        local client_pubkey_raw = x25519_to_raw(client_pubkey)

        local shared_secret = assert(client_seckey:derive(server_pubkey))

        -- ECDH_X25519_KDF()
        local ikm = sha256:digest(shared_secret .. client_pubkey_raw .. server_pubkey_raw)
        local prk = openssl.hmac.hmac(sha256, ikm, session_salt, true)
        local better_secret = openssl.hmac.hmac(sha256, "ECDH-X25519-CHALLENGE\1", prk, true)

        return snowcone.xor_strings(masked_challenge, better_secret)
    end)
end
