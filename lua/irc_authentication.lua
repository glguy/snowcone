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
    local commands = 'AUTHENTICATE ' .. mechanism .. '\r\n'

    while #body >= 400 do
        commands = commands .. 'AUTHENTICATE ' .. to_base64(string.sub(body, 1, 400)) .. '\r\n'
        body = string.sub(body, 401)
    end

    if "" == body then
        commands = commands .. 'AUTHENTICATE +\r\n'
    else
        commands = commands .. 'AUTHENTICATE ' .. to_base64(body) .. '\r\n'
    end

    return commands
end

return M
