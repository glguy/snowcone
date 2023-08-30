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
            send('AUTHENTICATE', '+')
        end
    else
        send('AUTHENTICATE', '*')
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

    -- If libidn is available, we SaslPrep all the authentiation strings
    local saslpassword = password -- normal password will get used for private key decryption
    if mystringprep then
        if authcid then
            if mechanism == 'ANONYMOUS' then
                authcid = mystringprep.stringprep(authcid, 'trace')
            else
                authcid = mystringprep.stringprep(authcid, 'SASLprep')
            end
        end
        if authzid then
            authzid = mystringprep.stringprep(authzid, 'SASLprep')
        end
        if saslpassword then
            saslpassword = mystringprep.stringprep(saslpassword, 'SASLprep')
        end
    end

    local co
    if mechanism == 'PLAIN' then
        co = require_ 'sasl.plain' (authzid, authcid, saslpassword)
    elseif mechanism == 'EXTERNAL' then
        co = require_ 'sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        key = load_key(key, password)
        co = require_ 'sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        key = load_key(key, password)
        co = require_ 'sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        co = require_ 'sasl.scram' ('sha1', authzid, authcid, saslpassword)
    elseif mechanism == 'SCRAM-SHA-256' then
        co = require_ 'sasl.scram' ('sha256', authzid, authcid, saslpassword)
    elseif mechanism == 'SCRAM-SHA-512' then
        co = require_ 'sasl.scram' ('sha512', authzid, authcid, saslpassword)
    elseif mechanism == 'ANONYMOUS' then
        co = require_ 'sasl.anonymous' (authcid)
    else
        error 'bad mechanism'
    end
    return {'AUTHENTICATE', mechanism}, co
end

-- install SASL state machine based on configuration values
-- and send the first AUTHENTICATE command
function M.start(credentials)
    local success, auth_cmd
    success, auth_cmd, irc_state.sasl = pcall(M.start_mech,
        credentials.mechanism,
        credentials.username,
        credentials.password,
        credentials.key,
        credentials.authzid
    )
    if success then
        send(table.unpack(auth_cmd))
    else
        status('sasl', 'startup failed: %s', auth_cmd)
    end
end

return M
