local openssl = require 'openssl'

local function scram_encode_username(name)
    local table = {
        [','] = '=2C',
        ['='] = '=3D',
    }
    return string.gsub(name, '[,=]', table)
end

local function hi(digest, secret, salt, iterations)
    local acc = openssl.hmac.hmac(digest, salt .. '\0\0\0\1', secret, true)
    local result = acc
    for _ = 2,iterations do
        acc = openssl.hmac.hmac(digest, acc, secret, true)
        result = snowcone.xor_strings(result, acc)
    end
    return result
end

-- 128-bits of random data base64 encoded to avoid special characters
local function make_nonce()
    return openssl.base64(string.pack('l', math.random(0)) .. string.pack('l', math.random(0)), true, true)
end

-- luacheck: ignore 631
return function(digest_name, authzid, authcid, password, nonce)
    local digest = openssl.digest.get(digest_name)

    return coroutine.create(function()
        local gs2_header
        if authzid then
            gs2_header = 'n,a=' .. scram_encode_username(authzid) .. ','
        else
            gs2_header = 'n,,'
        end
        local cbind_input = openssl.base64(gs2_header, true, true)
        local client_nonce = nonce or make_nonce()
        local client_first_bare = 'n=' .. scram_encode_username(authcid) .. ',r=' .. client_nonce
        local client_first = gs2_header .. client_first_bare

        --------------------------------------------------
        local server_first = coroutine.yield(client_first)
        local server_nonce, salt, iterations = string.match(server_first, '^r=([!-+--~]*),s=([%w+/]*=?=?),i=(%d+)$')
        assert(server_nonce, 'bad server initial')
        salt = assert(openssl.base64(salt, false, true), 'bad salt encoding')
        assert(server_nonce ~= client_nonce)
        assert(server_nonce:startswith(client_nonce))
        iterations = assert(math.tointeger(iterations), 'bad iteration count')

        local client_final_without_proof = 'c=' .. cbind_input .. ',r=' .. server_nonce
        local auth_message = client_first_bare .. ',' .. server_first .. ',' .. client_final_without_proof
        local salted_password = hi(digest, password, salt, iterations)
        local client_key = openssl.hmac.hmac(digest, 'Client Key', salted_password, true)
        local server_key = openssl.hmac.hmac(digest, 'Server Key', salted_password, true)
        local stored_key = digest:digest(client_key)
        local client_signature = openssl.hmac.hmac(digest, auth_message, stored_key, true)
        local server_signature = openssl.hmac.hmac(digest, auth_message, server_key, true)
        local client_proof = snowcone.xor_strings(client_key, client_signature)
        local proof = 'p=' .. openssl.base64(client_proof, true, true)
        local client_final = client_final_without_proof .. ',' .. proof

        --------------------------------------------------
        local server_final = coroutine.yield(client_final)
        local sig64 = assert(string.match(server_final, '^v=([%w+/]*=?=?)$'), 'bad server final')
        local sig = assert(openssl.base64(sig64, false, true), 'bad base64')
        assert(server_signature == sig)
        return ''
    end)
end
