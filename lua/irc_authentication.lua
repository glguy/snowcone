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

return M
