-- SASL authentication driver (from ircc/sasl/init.lua), run inside a
-- network task. https://ircv3.net/specs/extensions/sasl-3.1
--
-- The mechanisms in this directory are coroutine factories, unchanged
-- from ircc and covered by tests/test-sasl.lua there.

local N       <const> = require 'hub.lib.numerics'
local secrets <const> = require 'hub.runtime.secrets'

local M = {}

local sasl_commands <const> = {
    N.RPL_SASLSUCCESS,
    N.ERR_NICKLOCKED,
    N.ERR_SASLFAIL,
    N.ERR_SASLTOOLONG,
    N.ERR_SASLABORTED,
    N.ERR_SASLALREADY,
    "AUTHENTICATE",
}

-- Upper bound on a reassembled server message. Real challenges are tiny.
local MAX_PAYLOAD_BASE64 = 64 * 1024

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
local function send_authenticate(t, body, secret)
    body = mybase64.to_base64(body)
    local n = #body
    for i = 1, n, 400 do
        t:send('AUTHENTICATE', {content=string.sub(body, i, i+399), secret=secret})
    end
    if n % 400 == 0 then
        t:send('AUTHENTICATE', '+')
    end
end

-- > The client can abort an authentication by sending an asterisk as
-- > the data. The server will send a 906 numeric.
local function abort_sasl(t)
    t:send('AUTHENTICATE', '*')
end

local function mechanism_factory(mechanism, authcid, password, key, authzid, use_store)
    if mechanism == 'PLAIN' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'hub.net.sasl.plain' (authzid, authcid, password)
    elseif mechanism == 'EXTERNAL' then
        return require 'hub.net.sasl.external' (authzid)
    elseif mechanism == 'ECDSA-NIST256P-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, "missing sasl `key`")
        if use_store then
            key = myopenssl.pkey_from_store(key, true, password)
        else
            key = myopenssl.read_pem(key, true, password)
        end
        return require 'hub.net.sasl.ecdsa' (authzid, authcid, key)
    elseif mechanism == 'ECDH-X25519-CHALLENGE' then
        assert(authcid, "missing sasl `username`")
        assert(key, 'missing sasl `key`')
        if use_store then
            key = myopenssl.pkey_from_store(key, true, password)
        elseif key:find('-----BEGIN', 1, true) then
            -- PEM; `password` decrypts it when it's encrypted
            key = myopenssl.read_pem(key, true, password)
        else
            -- raw 32-byte X25519 private key, base64 encoded (never encrypted)
            key = assert(mybase64.from_base64(key), 'bad base64 in private sasl `key`')
            key = myopenssl.read_raw(myopenssl.types.EVP_PKEY_X25519, true, key)
        end
        return require 'hub.net.sasl.ecdh' (authzid, authcid, key)
    elseif mechanism == 'SCRAM-SHA-1'   then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'hub.net.sasl.scram' ('sha1', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-256' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'hub.net.sasl.scram' ('sha256', authzid, authcid, password)
    elseif mechanism == 'SCRAM-SHA-512' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        return require 'hub.net.sasl.scram' ('sha512', authzid, authcid, password)
    elseif mechanism == 'ANONYMOUS' then
        assert(authcid, "missing sasl `username`")
        return require 'hub.net.sasl.anonymous' (authcid)
    elseif mechanism == 'AUTHCOOKIE' then
        assert(authcid, "missing sasl `username`")
        assert(password, "missing sasl `password`")
        assert(authzid, "missing sasl `authzid`")
        -- AUTHCOOKIE uses the same AUTHENTICATE messages as PLAIN
        return require 'hub.net.sasl.plain' (authzid, authcid, password)
    else
        error 'unknown mechanism'
    end
end

--- Authenticate with one credential.
---@param t table network task
---@param credentials table a `sasl.credentials` entry
---@return boolean success
function M.authenticate(t, credentials)
    local mechanism = credentials.mechanism

    local pass_success, password = pcall(secrets.resolve, t, credentials.password)
    if not pass_success then
        t:log('sasl', 'Password resolution failed: %s', password)
        return false
    end

    local key_success, key = pcall(secrets.resolve, t, credentials.key)
    if not key_success then
        t:log('sasl', 'Key resolution failed: %s', key)
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
        t:log('sasl', 'Startup failed: %s %s', mechanism, impl)
        return false
    end

    t:send('AUTHENTICATE', mechanism)

    local outcome = true
    local chunks = {}
    local received = 0

    -- The exchange can no longer succeed: tell the server and keep waiting
    -- for its reply so the numeric doesn't leak into later handlers.
    local function fail_exchange(reason)
        t:log('sasl', '%s', reason)
        abort_sasl(t)
        outcome = false
        chunks = {}
        received = 0
    end

    while true do
        local irc = t:wait_irc(sasl_commands)
        local command = irc.command
        if command == 'AUTHENTICATE' then
            local chunk = irc[1]
            local bytes
            if chunk == '+' then
                bytes = ''
            elseif type(chunk) == 'string' and received + #chunk <= MAX_PAYLOAD_BASE64 then
                bytes = mybase64.from_base64(chunk)
            end

            if not bytes then
                fail_exchange('Bad AUTHENTICATE message from server')
            else
                received = received + #chunk
                table.insert(chunks, bytes)

                if #chunk < 400 then
                    local payload = table.concat(chunks)
                    chunks = {} -- prepare for next message
                    received = 0
                    local success, message, secret = coroutine.resume(impl, payload)
                    if success then
                        if message then
                            send_authenticate(t, message, secret)
                        end
                    elseif type(message) == 'table' and message.server_error then
                        -- The server reported the failure and will follow with
                        -- its own failure numeric. Record it so a later 903
                        -- can't turn this into a success, but send no abort.
                        t:log('sasl', 'Server error: %s', message.server_error)
                        outcome = false
                    else
                        fail_exchange('Mechanism error: ' .. tostring(message))
                    end
                end
            end
        elseif command == N.RPL_SASLSUCCESS then
            -- ensure the mechanism has completed
            -- the end of scram, for example, verifies the server
            if coroutine.status(impl) == 'dead' then
                t:log('sasl', 'SASL success')
                return outcome
            else
                t:log('sasl', 'SASL erroneous success')
                return false
            end
        elseif command == N.ERR_NICKLOCKED then
            -- "<client> :You must use a nick assigned to you"
            t:log('sasl', 'SASL failed: nick locked')
            return false
        elseif command == N.ERR_SASLTOOLONG then
            -- "<client> :SASL message too long"
            t:log('sasl', 'SASL failed: message too long')
            return false
        elseif command == N.ERR_SASLALREADY then
            -- "<client> :You have already authenticated using SASL"
            t:log('sasl', 'SASL failed: already authenticated')
            return false
        elseif command == N.ERR_SASLFAIL then
            -- "<client> :SASL authentication failed"
            t:log('sasl', 'SASL failed')
            return false
        elseif command == N.ERR_SASLABORTED then
            -- "<client> :SASL authentication aborted"
            t:log('sasl', 'SASL aborted')
            return false
        end
    end
end

return M
