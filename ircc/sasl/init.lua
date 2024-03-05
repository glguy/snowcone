-- https://ircv3.net/specs/extensions/sasl-3.1
-- https://ircv3.net/specs/extensions/sasl-3.1

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

local function mechanism_factory(mechanism, authcid, password, key, authzid)
    if mechanism == 'PLAIN' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require_ 'sasl.plain' (authzid, authcid, password)
    elseif mechanism == 'EXTERNAL' then
        return require_ 'sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, "missing sasl `key`")
        key = assert(file.read(key))
        key = assert(myopenssl.read_pkey(key, true, password))
        return require_ 'sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, 'missing sasl `key`')
        key = assert(snowcone.from_base64(key), 'bad base64 in private sasl `key`')
        key = assert(myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, true, key))
        return require_ 'sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require_ 'sasl.scram' ('sha1', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-256' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require_ 'sasl.scram' ('sha256', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-512' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require_ 'sasl.scram' ('sha512', authzid, authcid, password)
    elseif mechanism == 'ANONYMOUS' then
        assert(authcid, "missing sasl `username`")
        return require_ 'sasl.anonymous' (authcid)
    else
        error 'unknown mechanism'
    end
end

-- Main body for a Task
return function(task, credentials)
    local mechanism = credentials.mechanism
    local mech_success, impl = pcall(mechanism_factory,
        mechanism,
        credentials.username,
        credentials.password,
        credentials.key,
        credentials.authzid
    )
    if not mech_success then
        status('sasl', 'Startup failed: %s %s', mechanism, impl)
        return false
    end

    send('AUTHENTICATE', mechanism)

    local outcome = true
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

                if payload == nil then
                    status('sasl', 'Bad base64 in AUTHENTICATE')
                    send_authenticate() -- abort
                    outcome = false
                else
                    local success, message, secret = coroutine.resume(impl, payload)
                    if success then
                        if message then
                            send_authenticate(message, secret)
                        end
                    else
                        status('sasl', 'Mechanism error: %s', message)
                        send_authenticate() -- abort
                        outcome = false
                    end
                end
            end
        elseif command == N.RPL_SASLSUCCESS then
            -- ensure the mechanism has completed
            -- the end of scram, for example, verifies the server
            if coroutine.status(impl) == 'dead' then
                status('sasl', 'SASL success')
                return outcome
            else
                status('sasl', 'SASL erroneous success')
                return false
            end
        elseif command == N.ERR_SASLFAIL then
            -- "<client> :SASL authentication failed"
            status('sasl', 'SASL failed')
            return false
        elseif command == N.ERR_SASLABORTED then
            -- "<client> :SASL authentication aborted"
            status('sasl', 'SASL aborted')
            return false
        elseif command == N.ERR_SASLALREADY then
            -- "<client> :You have already authenticated using SASL"
            status('sasl', 'SASL already complete')
            return false
        elseif command == N.ERR_NICKLOCKED then
            -- "<client> :You must use a nick assigned to you
            status('sasl', 'Must use assigned nickname')
            return false
        end
    end
end
