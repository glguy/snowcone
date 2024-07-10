-- https://ircv3.net/specs/extensions/sasl-3.1

local Set                 <const> = require 'pl.Set'
local send                <const> = require 'utils.send'
local N                   <const> = require 'utils.numerics'
local configuration_tools <const> = require 'utils.configuration_tools'

local sasl_commands = Set{
    N.RPL_SASLSUCCESS,
    N.ERR_SASLFAIL,
    N.ERR_SASLABORTED,
    "AUTHENTICATE",
}

-- Transmit the AUTHENTICATE message for the given raw SASL message.
--
-- body (string): unencoded SASL bytes
-- secret (bool): message contains sensitive information
--
-- > The response is encoded in Base64 (RFC 4648), then split to 400-byte
-- > chunks, and each chunk is sent as a separate `AUTHENTICATE` command.
-- > Empty (zero-length) responses are sent as `AUTHENTICATE +`. If the last
-- > chunk was exactly 400 bytes long, it must also be followed by
-- > `AUTHENTICATE +` to signal end of response.
local function send_authenticate(body, secret)
    body = snowcone.to_base64(body)
    local n = #body
    for i = 1, n, 400 do
        send('AUTHENTICATE', {content=string.sub(body, i, i+399), secret=secret})
    end
    if n % 400 == 0 then
        send('AUTHENTICATE', '+')
    end
end

-- > The client can abort an authentication by sending an asterisk as
-- > the data. The server will send a 906 numeric.
local function abort_sasl()
    send('AUTHENTICATE', '*')
end

local function mechanism_factory(mechanism, authcid, password, key, authzid, use_store)
    if mechanism == 'PLAIN' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'sasl.plain' (authzid, authcid, password)
    elseif mechanism == 'EXTERNAL' then
        return require 'sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, "missing sasl `key`")
        if use_store then
            key = myopenssl.pkey_from_store(key, true, password)
        else
            key = myopenssl.read_pem(key, true, password)
        end
        return require 'sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, 'missing sasl `key`')
        if use_store then
            key = myopenssl.pkey_from_store(key, true, password)
        else
            key = assert(snowcone.from_base64(password), 'bad base64 in private sasl `key`')
            key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, true, key)
        end
        return require 'sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'sasl.scram' ('sha1', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-256' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'sasl.scram' ('sha256', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-512' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'sasl.scram' ('sha512', authzid, authcid, password)
    elseif mechanism == 'ANONYMOUS' then
        assert(authcid, "missing sasl `username`")
        return require 'sasl.anonymous' (authcid)
    elseif mechanism == 'AUTHCOOKIE' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        assert(authzid, "missing sasl `authzid`")
        -- AUTHCOOKIE uses the same AUTHENTICATE messages as PLAIN
        return require 'sasl.plain' (authzid, authcid, password)
    else
        error 'unknown mechanism'
    end
end

-- Main body for a Task
return function(task, credentials)
    local mechanism = credentials.mechanism

    local pass_success, password = pcall(configuration_tools.resolve_password, task, credentials.password)
    if not pass_success then
        status('sasl', 'Password resolution failed: %s', password)
        return false
    end

    local key_success, key = pcall(configuration_tools.resolve_password, task, credentials.key)
    if not key_success then
        status('sasl', 'Key resolution failed: %s', key)
        return false
    end

    local mech_success, impl = pcall(mechanism_factory,
        mechanism,
        credentials.username,
        password,
        key,
        credentials.authzid,
        credentials.use_store
    )
    if not mech_success then
        status('sasl', 'Startup failed: %s %s', mechanism, impl)
        return false
    end

    send('AUTHENTICATE', mechanism)

    local outcome = true
    local chunks = {}
    while true do
        local irc = task:wait_irc(sasl_commands)
        local command = irc.command
        if command == 'AUTHENTICATE' then
            local chunk = irc[1]
            if chunk ~= '+' then
                local bytes = assert(snowcone.from_base64(chunk), 'Bad base64 in AUTHENTICATE')
                table.insert(chunks, bytes)
            end

            if #chunk < 400 then
                local payload = table.concat(chunks)
                chunks = {} -- prepare for next message
                local success, message, secret = coroutine.resume(impl, payload)
                if success then
                    if message then
                        send_authenticate(message, secret)
                    end
                else
                    status('sasl', 'Mechanism error: %s', message)
                    abort_sasl()
                    outcome = false
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
        end
    end
end
