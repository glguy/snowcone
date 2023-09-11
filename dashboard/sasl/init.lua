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

local function prep(str, profile)
    if mystringprep and str then
        return mystringprep.stringprep(str, profile)
    else
        return str
    end
end

local function mechanism_factory(mechanism, authcid, password, key, authzid)

    authcid = prep(authcid, mechanism == 'ANONYMOUS' and 'trace' or 'SASLprep')
    authzid = prep(authzid, 'SASLprep')
    local saslpassword = prep(password, 'SASLprep')

    if mechanism == 'PLAIN' then
        return require_ 'sasl.plain' (authzid, authcid, saslpassword)
    elseif mechanism == 'EXTERNAL' then
        return require_ 'sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        assert(key, "sasl key file not specified `key`")
        key = assert(file.read(key), 'failed to read sasl key file')
        key = assert(myopenssl.read_pkey(key, true, password))
        return require_ 'sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        assert(key, 'missing private key')
        key = assert(snowcone.from_base64(key), 'bad base64 in private key')
        key = assert(myopenssl.read_raw(myopenssl.EVP_PKEY_X25519, true, key))
        return require_ 'sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        return require_ 'sasl.scram' ('sha1', authzid, authcid, saslpassword)
    elseif mechanism == 'SCRAM-SHA-256' then
        return require_ 'sasl.scram' ('sha256', authzid, authcid, saslpassword)
    elseif mechanism == 'SCRAM-SHA-512' then
        return require_ 'sasl.scram' ('sha512', authzid, authcid, saslpassword)
    elseif mechanism == 'ANONYMOUS' then
        return require_ 'sasl.anonymous' (authcid)
    else
        error 'bad mechanism'
    end
end

-- Main body for a Task
return function(task, credentials, disconnect_on_failure)
    local mechanism = credentials.mechanism
    local success, impl = pcall(mechanism_factory,
        mechanism,
        credentials.username,
        credentials.password,
        credentials.key,
        credentials.authzid
    )
    if not success then
        status('sasl', 'Startup failed: %s', mechanism)
        return
    end

    send('AUTHENTICATE', mechanism)

    local chunks = {}
    local n = 0
    while true do
        local irc = task:wait_irc(sasl_commands)
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
                    status('sasl', 'Bad base64 in AUTHENTICATE')
                else
                    local message
                    success, message, secret = coroutine.resume(impl, payload)
                    if success then
                        reply = message
                    else
                        status('sasl', 'Mechanism error: %s', message)
                    end
                end

                if not reply and disconnect_on_failure then
                    goto failure
                end

                send_authenticate(reply, secret)
            end
        elseif command == N.RPL_SASLSUCCESS then
            -- ensure the mechanism has completed
            -- the end of scram, for example, verifies the server
            if coroutine.status(impl) == 'dead' then
                status('sasl', 'SASL success')
                return
            else
                status('sasl', 'Unexpected success')
                goto failure
            end
        elseif command == N.ERR_SASLFAIL then
            -- "<client> :SASL authentication failed"
            status('sasl', 'SASL failed')
            goto failure
        elseif command == N.ERR_SASLABORTED then
            -- "<client> :SASL authentication aborted"
            status('sasl', 'SASL aborted')
            goto failure
        elseif command == N.RPL_SASLMECHS then
            -- "<client> <mechanisms> :are available SASL mechanisms"
            status('sasl', 'SASL mechanism unsupported: %s', irc[2])
            goto failure
        elseif command == N.ERR_SASLTOOLONG then
            -- "<client> :SASL message too long"
            status('sasl', 'SASL too long')
            goto failure
        elseif command == N.ERR_SASLALREADY then
            -- "<client> :You have already authenticated using SASL"
            status('sasl', 'SASL already complete')
            goto failure
        end
    end

    ::failure::
    if disconnect_on_failure then
        disconnect()
    end
end
