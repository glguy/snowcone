local Set = require 'pl.Set'
local file = require 'pl.file'
local send = require_ 'utils.send'
local N = require 'utils.numerics'

local sasl_commands = Set{
    N.RPL_SASLSUCCESS,
    N.ERR_SASLFAIL,
    N.ERR_SASLABORTED,
    N.RPL_SASLMECHS,
    N.ERR_SASLALREADY,
    N.ERR_SASLTOOLONG,
    "AUTHENTICATE",
}

-- Takes a binary argument, base64 encodes it, and chunks it into multiple
-- AUTHENTICATE commands
local function send_authenticate(body, secret)
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
    assert(key, "sasl key file not specified `key`")
    key = assert(file.read(key), 'failed to read sasl key file')
    key = assert(myopenssl.read_pkey(key, true, password))
    return key
end

local function start_mech(mechanism, authcid, password, key, authzid)

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
        assert(key, 'missing private key')
        key = assert(snowcone.from_base64(key), 'bad base64 in private key')
        key = assert(myopenssl.read_raw(myopenssl.EVP_PKEY_X25519, true, key))
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
    send('AUTHENTICATE', mechanism)
    return co
end

-- Main body for a Task
return function(self, credentials, disconnect_on_failure)
    local success, mechanism = pcall(start_mech,
        credentials.mechanism,
        credentials.username,
        credentials.password,
        credentials.key,
        credentials.authzid
    )
    if not success then
        status('sasl', 'startup failed: %s', mechanism)
        return
    end

    local chunks = {}
    local n = 0
    while true do
        local irc = self:wait_irc(sasl_commands)
        local command = irc.command
        if command == 'AUTHENTICATE' then
            local chunk = irc[1]
            if chunk == '+' then
                chunk = ''
            end

            n = n + 1
            chunks[n] = chunk

            if #chunk < 400 then
                local payload = snowcone.from_base64(table.concat(chunks))
                chunks = {}
                n = 0

                local reply, secret
                if payload == nil then
                    status('sasl', 'bad authenticate base64')
                else
                    local message
                    success, message, secret = coroutine.resume(mechanism, payload)
                    if success then
                        reply = message
                    else
                        status('sasl', 'mechanism error: %s', message)
                    end
                end
                if reply or not disconnect_on_failure then
                    send_authenticate(reply, secret)
                else
                    disconnect()
                    return
                end
            end
        elseif command == N.RPL_SASLSUCCESS then
            status('irc', 'SASL success')
            return
        else
            -- these are all errors and are terminal
            if command == N.ERR_SASLFAIL then
                status('irc', 'SASL failed')
            elseif command == N.ERR_SASLABORTED then
                status('irc', 'SASL aborted')
            elseif command == N.RPL_SASLMECHS then
                status('irc', 'SASL mechanism unsupported')
            elseif command == N.ERR_SASLTOOLONG then
                status('irc', 'SASL too long')
            elseif command == N.ERR_SASLALREADY then
                status('irc', 'SASL already complete')
            end

            if disconnect_on_failure then
                disconnect()
            end
            return
        end
    end
end
