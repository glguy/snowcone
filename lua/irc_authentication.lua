local class = require 'pl.class'

local M = {}

function M.challenge(key_txt, password, challenge)
    local openssl  = require 'openssl'
    local sha1     = openssl.digest.get 'sha1'
    local key      = assert(openssl.pkey.read(key_txt, true, 'auto', password))
    local envelope = assert(openssl.base64(challenge, false, true), 'bad base64')
    local message  = assert(key:decrypt(envelope, 'oaep'))
    local digest   = sha1:digest(message)
    local response = openssl.base64(digest, true, true)
    return response
end

-- Takes a binary argument, base64 encodes it, and chunks it into multiple
-- AUTHENTICATE commands
function M.encode_authenticate(body)
    if body == nil then
        return 'AUTHENTICATE *\r\n'
    end

    local commands = {}

    local function authenticate(msg)
        table.insert(commands, 'AUTHENTICATE ' .. msg .. '\r\n')
    end

    body = snowcone.to_base64(body)
    while #body >= 400 do
        authenticate(string.sub(body, 1, 400))
        body = string.sub(body, 401)
    end

    if '' == body then
        authenticate('+')
    else
        authenticate(body)
    end

    return table.concat(commands)
end

function M.decode_authenticate(payload)
    if payload == '+' then
        return ''
    else
        return assert(snowcone.from_base64(payload))
    end
end

function M.ecdsa_challenge(key_txt, key_password, challenge)
    local openssl   = require 'openssl'
    local key       = openssl.pkey.read(key_txt, true, 'auto', key_password)
    local signature = key:sign(challenge)
    return signature
end

local function x25519_to_raw(pubkey)
    return string.sub(pubkey:export('der'), 13, 44)
end

local function raw_to_x25519(raw)
    local openssl = require 'openssl'
    return openssl.pkey.read(
        "\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00" .. raw,
        false, 'der')
end

function M.ecdh_challenge(key_txt, key_password, server_response)
    assert(#server_response == 96)

    local openssl = require 'openssl'
    local sha256  = openssl.digest.get 'sha256'

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
end

M.Scram = class()
M.Scram._name = "Scram"

function M.Scram:_init(digest_name, authz, authc, password)
    local openssl = require 'openssl'
    self.digest = openssl.digest.get(digest_name)
    self.authz = authz
    self.authc = authc
    self.nonce = openssl.base64(string.pack('l', math.random(0)) .. string.pack('l', math.random(0)), true, true)
    self.password = password
end

local function scram_encode_username(name)
    local table = {
        [','] = '=2C',
        ['='] = '=3D',
    }
    return string.gsub(name, '[,=]', table)
end

function M.Scram:client_first()
    local openssl = require 'openssl'
    local gs2_header = 'n,' .. scram_encode_username(self.authz or '') .. ','
    self.cbind_input = openssl.base64(gs2_header, true, true)
    self.client_first_bare = 'n=' .. scram_encode_username(self.authc) .. ',r=' .. self.nonce
    return gs2_header .. self.client_first_bare
end

local function hi(digest, secret, salt, iterations)
    local openssl = require 'openssl'
    local acc = openssl.hmac.hmac(digest, salt .. '\0\0\0\1', secret, true)
    local result = acc
    for _ = 2,iterations do
        acc = openssl.hmac.hmac(digest, acc, secret, true)
        result = snowcone.xor_strings(result, acc)
    end
    return result
end

function M.Scram:do_crypto(salt, iterations, auth_message)
    local openssl = require 'openssl'
    local salted_password = hi(self.digest, self.password, salt, iterations)
    local client_key = openssl.hmac.hmac(self.digest, 'Client Key', salted_password, true)
    local server_key = openssl.hmac.hmac(self.digest, 'Server Key', salted_password, true)
    local stored_key = self.digest:digest(client_key)
    local client_signature = openssl.hmac.hmac(self.digest, auth_message, stored_key, true)
    self.server_signature = openssl.hmac.hmac(self.digest, auth_message, server_key, true)
    return snowcone.xor_strings(client_key, client_signature)
end

function M.Scram:client_final(server_first)
    local openssl = require 'openssl'

    local nonce, salt, iterations = string.match(server_first, '^r=([^,]*),s=([^,]*),i=([^,]*)')

    salt = assert(openssl.base64(salt, false, true), 'bad salt')

    assert(nonce ~= self.nonce)
    assert(nonce:startswith(self.nonce))

    iterations = math.tointeger(iterations)
    assert(iterations)

    local client_final_without_proof = 'c=' .. self.cbind_input .. ',r=' .. nonce
    local auth_message =
        self.client_first_bare .. ',' ..
        server_first .. ',' ..
        client_final_without_proof
    local client_proof = self:do_crypto(salt, iterations, auth_message)
    local proof = 'p=' .. openssl.base64(client_proof, true, true)
    return client_final_without_proof .. ',' .. proof
end

function M.Scram:verify(server_final)
    local openssl = require 'openssl'
    local signature64 = assert(string.match(server_final, '^v=([^,]*)'), 'bad envelope')
    local signature = assert(openssl.base64(signature64, false, true), 'bad base64')
    assert(self.server_signature == signature)
    return ''
end

return M
