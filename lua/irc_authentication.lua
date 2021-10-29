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
    local commands = {}
    local n = 0

    local function authenticate(msg)
        n = n + 1
        commands[n] = 'AUTHENTICATE ' .. msg .. '\r\n'
    end

    if body then
        body = snowcone.to_base64(body)
        while #body >= 400 do
            authenticate(string.sub(body, 1, 400))
            body = string.sub(body, 401)
        end

        if '' == body then
            body = '+'
        end
        authenticate(body)
    else
        authenticate '*'
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

return M
