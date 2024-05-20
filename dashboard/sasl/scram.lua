-- Salted Challenge Response Authentication Mechanism (SCRAM) SASL and GSS-API Mechanisms
-- https://datatracker.ietf.org/doc/html/rfc5802

-- minimum length nonce we should accept from the server
local MIN_NONCE_LEN = 8

-- https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2
-- Derived from twice the recommendation as of February 2024
local PBKDF2_ITERATION_LIMIT = {
    sha1   = 2 * 1300000,
    sha256 = 2 *  600000,
    sha512 = 2 *  210000,
}

local xor_strings = snowcone.xor_strings
local to_base64 = snowcone.to_base64
local from_base64 = snowcone.from_base64

local function scram_encode_username(name)
    local table = {
        [','] = '=2C',
        ['='] = '=3D',
    }
    return string.gsub(name, '[,=]', table)
end

-- luacheck: ignore 631
return function(digest_name, authzid, authcid, password, nonce)
    local digest = myopenssl.get_digest(digest_name)
    local iteration_limit = assert(PBKDF2_ITERATION_LIMIT[digest_name], 'no iteration limit defined')

    if mystringprep then
        authcid = mystringprep.stringprep(authcid, 'SASLprep')
        authzid = authzid and mystringprep.stringprep(authzid, 'SASLprep')
        password = mystringprep.stringprep(password, 'SASLprep')
    end

    return coroutine.create(function()
        local gs2_header
        if authzid then
            gs2_header = 'n,a=' .. scram_encode_username(authzid) .. ','
        else
            gs2_header = 'n,,'
        end
        local cbind_input = to_base64(gs2_header)
        local client_nonce = nonce or to_base64(myopenssl.rand(16))
        local client_first_bare = 'n=' .. scram_encode_username(authcid) .. ',r=' .. client_nonce
        local client_first = gs2_header .. client_first_bare

        --------------------------------------------------
        local server_first = coroutine.yield(client_first)
        if server_first:startswith 'e=' then
            return
        end

        local server_nonce, salt, iterations = string.match(server_first, '^r=([!-+--~]*),s=([%w+/]*=?=?),i=(%d+)$')
        assert(server_nonce, 'bad server initial')
        salt = assert(from_base64(salt), 'bad salt encoding')
        assert(server_nonce:startswith(client_nonce), 'server nonce does not match client nonce')
        assert(#server_nonce - #client_nonce >= MIN_NONCE_LEN, 'server nonce too short')
        iterations = assert(math.tointeger(iterations), 'bad iteration count')
        assert(iterations <= iteration_limit, 'server pbdkf2 iteration count too high')

        local salted_password = digest:pbkdf2(password, salt, iterations, digest:size())
        local client_key = digest:hmac('Client Key', salted_password)
        local server_key = digest:hmac('Server Key', salted_password)
        local stored_key = digest:digest(client_key)

        local client_final_without_proof = 'c=' .. cbind_input .. ',r=' .. server_nonce
        local auth_message = client_first_bare .. ',' .. server_first .. ',' .. client_final_without_proof
        local client_signature = digest:hmac(auth_message, stored_key)
        local server_signature = digest:hmac(auth_message, server_key)

        local client_proof = xor_strings(client_key, client_signature)
        local proof = 'p=' .. to_base64(client_proof)
        local client_final = client_final_without_proof .. ',' .. proof

        --------------------------------------------------
        local server_final = coroutine.yield(client_final)
        if server_final:startswith 'e=' then
            return
        end

        local sig64 = assert(string.match(server_final, '^v=([%w+/]*=?=?)$'), 'bad server final')
        local sig = assert(from_base64(sig64), 'bad server final signature base64')
        assert(server_signature == sig, 'bad server final signature')
        return ''
    end)
end
