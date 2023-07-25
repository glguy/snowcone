local file = require 'pl.file'

local M = {}

-- Takes a binary argument, base64 encodes it, and chunks it into multiple
-- AUTHENTICATE commands
function M.encode_authenticate(body)
    local commands = {}
    local n = 0

    local function authenticate(msg)
        n = n + 1
        commands[n] = {'AUTHENTICATE', {content=msg, secret=true}}
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

    return commands
end

local function load_key(key, password)
    local openssl = require 'openssl'
    assert(key, "key file not specified (-D)")
    key = assert(file.read(key))
    key = assert(openssl.pkey.read(key, true, 'auto', password))
    return key
end

function M.start(mechanism, authcid, password, key, authzid)
    local co
    if mechanism == 'PLAIN' then
        co = require_ 'sasl.plain' (authzid, authcid, password)
    elseif mechanism == 'EXTERNAL' then
        co = require_ 'sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        key = load_key(key, password)
        co = require_ 'sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        key = load_key(key, password)
        co = require_ 'sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        co = require_ 'sasl.scram' ('sha1', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-256' then
        co = require_ 'sasl.scram' ('sha256', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-512' then
        co = require_ 'sasl.scram' ('sha512', authzid, authcid, password)
    else
        error 'bad mechanism'
    end
    return {'AUTHENTICATE', mechanism}, co
end

return M
