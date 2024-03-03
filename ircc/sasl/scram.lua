-- minimum length nonce we should accept from the server
local MIN_NONCE_LEN = 8

-- https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2
-- Derived from twice the recommendation as of February 2024
local PBKDF2_ITERATION_LIMIT = {
    sha1   = 2 * 1300000,
    sha256 = 2 *  600000,
    sha512 = 2 *  210000,
}

local function scram_encode_username(name)
    local table = {
        [','] = '=2C',
        ['='] = '=3D',
    }
    return string.gsub(name, '[,=]', table)
end

-- Hi() is, essentially, PBKDF2 [RFC2898] with HMAC() as the
-- pseudorandom function (PRF) and with dkLen == output length of
-- HMAC() == output length of H().
local function hi(digest, secret, salt, iterations)
    local acc = digest:hmac(salt .. '\0\0\0\1', secret)
    local result = acc
    for _ = 2,iterations do
        acc = digest:hmac(acc, secret)
        result = snowcone.xor_strings(result, acc)
    end
    return result
end

-- 128-bits of random data base64 encoded to avoid special characters
local function make_nonce()
    return snowcone.to_base64(string.pack('i8', math.random(0)) .. string.pack('i8', math.random(0)))
end

-- luacheck: ignore 631
return function(digest_name, authzid, authcid, password, nonce)
    local digest = myopenssl.get_digest(digest_name)
    local iteration_limit = assert(PBKDF2_ITERATION_LIMIT[digest_name], 'no iteration limit defined')

    return coroutine.create(function()
        local gs2_header
        if authzid then
            gs2_header = 'n,a=' .. scram_encode_username(authzid) .. ','
        else
            gs2_header = 'n,,'
        end
        local cbind_input = snowcone.to_base64(gs2_header)
        local client_nonce = nonce or make_nonce()
        local client_first_bare = 'n=' .. scram_encode_username(authcid) .. ',r=' .. client_nonce
        local client_first = gs2_header .. client_first_bare

        --------------------------------------------------
        local server_first = coroutine.yield(client_first)
        if server_final:startswith 'e=' then
            local errmsg = server_final:sub(3)
            error('SCRAM server error: ' .. errmsg, 2)
        end

        local server_nonce, salt, iterations = string.match(server_first, '^r=([!-+--~]*),s=([%w+/]*=?=?),i=(%d+)$')
        assert(server_nonce, 'bad server initial')
        salt = assert(snowcone.from_base64(salt), 'bad salt encoding')
        assert(server_nonce:startswith(client_nonce), 'server nonce does not match client nonce')
        assert(#server_nonce - #client_nonce >= MIN_NONCE_LEN, 'server nonce too short')
        iterations = assert(math.tointeger(iterations), 'bad iteration count')
        assert(iterations <= iteration_limit, 'server pbdkf2 iteration count too high')

        local salted_password = hi(digest, password, salt, iterations)
        local client_key = digest:hmac('Client Key', salted_password)
        local server_key = digest:hmac('Server Key', salted_password)
        local stored_key = digest:digest(client_key)

        local client_final_without_proof = 'c=' .. cbind_input .. ',r=' .. server_nonce
        local auth_message = client_first_bare .. ',' .. server_first .. ',' .. client_final_without_proof
        local client_signature = digest:hmac(auth_message, stored_key)
        local server_signature = digest:hmac(auth_message, server_key)

        local client_proof = snowcone.xor_strings(client_key, client_signature)
        local proof = 'p=' .. snowcone.to_base64(client_proof)
        local client_final = client_final_without_proof .. ',' .. proof

        --------------------------------------------------
        local server_final = coroutine.yield(client_final)
        if server_final:startswith 'e=' then
            local errmsg = server_final:sub(3)
            error('SCRAM server error: ' .. errmsg, 2)
        end
        local sig64 = assert(string.match(server_final, '^v=([%w+/]*=?=?)$'), 'bad server final')
        local sig = assert(snowcone.from_base64(sig64), 'bad server final signature base64')
        assert(server_signature == sig, 'bad server final signature')
        return ''
    end)
end
