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

function M.sasl(mechanism, body)
    local commands = {}

    local function authenticate(msg)
        table.insert(commands, 'AUTHENTICATE ' .. msg .. '\r\n')
    end

    authenticate(mechanism)

    body = snowcone.to_base64(body)
    while #body >= 400 do
        authenticate(string.sub(body, 1, 400))
        body = string.sub(body, 401)
    end

    if "" == body then
        authenticate('+')
    else
        authenticate(body)
    end

    return table.concat(commands)
end

function M.ecdsa_challenge(key_der, challenge)
    local openssl  = require 'openssl'
    local key = openssl.ec.read(key_der)
    local bytes = assert(openssl.base64(challenge, false, true), 'bad base64')
    local signature = openssl.ec.sign(key, bytes)
    local response = openssl.base64(signature, true, true)
    return response
end

return M
