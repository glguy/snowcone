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
        local openssl = require 'openssl'
        return assert(openssl.base64(payload, false, true), 'bad base64')
    end
end

function M.ecdsa_challenge(key_der, challenge)
    local openssl   = require 'openssl'
    local key       = openssl.ec.read(key_der)
    local signature = openssl.ec.sign(key, challenge)
    return signature
end

return M
