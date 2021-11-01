local file = require 'pl.file'

local M = {}

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

function M.start(mechanism, authcid, password, key, authzid)
    local co
    if mechanism == 'PLAIN' then
        co = require_ 'sasl.plain' (authzid, authcid, password)
    elseif mechanism == 'EXTERNAL' then
        co = require_ 'sasl.external' (configuration.irc_sasl_authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        key = assert(file.read(key))
        co = require_ 'sasl.ecdsa' (authzid, authcid, key, password)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        key = assert(file.read(key))
        co = require_ 'sasl.ecdh' (authzid, authcid, key, password)
    elseif mechanism == 'SCRAM-SHA-1'   then
        co = require_ 'sasl.scram' ('sha1', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-256' then
        co = require_ 'sasl.scram' ('sha256', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-512' then
        co = require_ 'sasl.scram' ('sha512', authzid, authcid, password)
    else
        error 'bad mechanism'
    end
    return 'AUTHENTICATE ' .. mechanism .. '\r\n', co
end

return M