local file = require 'pl.file'
local send = require_ 'utils.send'

local M = {}

-- Takes a binary argument, base64 encodes it, and chunks it into multiple
-- AUTHENTICATE commands
function M.authenticate(body, secret)
    if body then
        body = snowcone.to_base64(body)
        local n = #body
        for i = 1, n, 400 do
            send('AUTHENTICATE', {content=string.sub(body, i, i+399), secret=secret})
        end
        if n % 400 == 0 then
            authenticate '+'
        end
    else
        authenticate '*'
    end
end

local function load_key(key, password)
    local openssl = require 'openssl'
    assert(key, "sasl key file not specified `irc_sasl_key`")
    key = assert(file.read(key), 'failed to read sasl key file')
    key = assert(openssl.pkey.read(key, true, 'auto', password))
    return key
end

function M.start_mech(mechanism, authcid, password, key, authzid)
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

-- install SASL state machine based on configuration values
-- and send the first AUTHENTICATE command
function M.start()
    local success, auth_cmd
    success, auth_cmd, irc_state.sasl = pcall(M.start_mech,
        configuration.irc_sasl_mechanism,
        configuration.irc_sasl_username,
        configuration.irc_sasl_password,
        configuration.irc_sasl_key,
        configuration.irc_sasl_authzid
    )
    if success then
        send(table.unpack(auth_cmd))
    else
        status('sasl', 'startup failed: %s', auth_cmd)
    end
end

return M
