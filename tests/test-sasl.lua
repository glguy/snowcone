-- Driver- and mechanism-level tests for hub/net/sasl.
-- The real mybase64, myopenssl and (when built) mystringprep come from
-- snowcone; only I/O and Penlight are replaced by small fakes.
--
-- Run with:  snowcone tests/test-sasl.lua

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'

assert(mybase64 and myopenssl, 'run this with snowcone')
local real_myopenssl <const> = myopenssl
local real_mystringprep <const> = mystringprep

-- Key loading is replaced per test; everything else is the real library
local function stub_myopenssl(overrides)
    myopenssl = setmetatable(overrides, {__index = real_myopenssl})
end

------------------------------------------------------------------------
-- fakes

local sent, statuses

-- hub resolves secrets in a task; these tests pass them as plain strings
package.preload['hub.runtime.secrets'] = function()
    return {
        resolve = function(_, v) return v end,
        key_store = function(v) return type(v) == 'table' and v.store or nil end,
    }
end

package.path = here .. '/../?.lua;' .. here .. '/../?/init.lua;' .. package.path
local N <const> = require 'hub.lib.numerics'
local sasl <const> = require 'hub.net.sasl'.authenticate

-- hub waits on a list of commands
local function waits_for(wanted, command)
    for _, c in ipairs(wanted) do
        if c == command then return true end
    end
    return false
end

local function run(credentials, script)
    sent, statuses = {}, {}
    local i = 0
    local task = {
        wait_irc = function(_, wanted)
            i = i + 1
            local msg = assert(script[i], 'driver kept waiting after the script ended')
            assert(waits_for(wanted, msg.command), 'driver does not wait for ' .. tostring(msg.command))
            return msg
        end,
        -- hub's driver sends and logs through its task
        send = function(_, command, arg)
            local text = type(arg) == 'table' and arg.content or arg
            sent[#sent + 1] = command .. ' ' .. tostring(text)
        end,
        log = function(_, _, fmt, ...) statuses[#statuses + 1] = fmt:format(...) end,
    }
    local result = sasl(task, credentials)
    return result, i == #script
end

local function auth(payload) return {command = 'AUTHENTICATE', payload} end
local function numeric(n) return {command = n} end

local function expect(cond, what)
    if not cond then error('FAILED: ' .. what, 2) end
end


do

    ------------------------------------------------------------------------
    -- PLAIN end to end

    do
        local ok = run({mechanism = 'PLAIN', username = 'u', password = 'p'},
            {auth '+', numeric(N.RPL_SASLSUCCESS)})
        expect(ok == true, 'plain succeeds')
        expect(sent[1] == 'AUTHENTICATE PLAIN', 'mechanism announced')
        expect(sent[2] == 'AUTHENTICATE ' .. mybase64.to_base64('\0u\0p'), 'plain payload')
    end

    -- long responses are split into 400 byte chunks
    do
        local pw = ('x'):rep(500)
        run({mechanism = 'PLAIN', username = 'u', password = pw},
            {auth '+', numeric(N.RPL_SASLSUCCESS)})
        expect(#sent == 3, 'mechanism + 2 chunks, got ' .. #sent)
        expect(#sent[2] == #'AUTHENTICATE ' + 400, 'first chunk is 400 bytes')
    end

    -- a response of exactly 400 base64 bytes is followed by '+'
    do
        local pw = ('x'):rep(300 - #'\0u\0')
        run({mechanism = 'PLAIN', username = 'u', password = pw},
            {auth '+', numeric(N.RPL_SASLSUCCESS)})
        expect(sent[#sent] == 'AUTHENTICATE +', 'terminating + after exact multiple')
    end

    -- NUL in a field is refused instead of shifting the fields
    do
        for _, c in ipairs{
            {mechanism = 'PLAIN', username = 'u\0evil', password = 'p'},
            {mechanism = 'PLAIN', username = 'u', password = 'p\0q'},
            {mechanism = 'PLAIN', username = 'u', password = 'p', authzid = 'a\0b'},
        } do
            local ok = run(c, {})
            expect(ok == false, 'NUL rejected')
            expect(#sent == 0, 'nothing sent when startup fails')
        end
    end

    -- a configuration problem is logged as a message, without a source position
    do
        for _, c in ipairs{
            {{mechanism = 'PLAIN', password = 'p'}, 'Startup failed: PLAIN missing sasl `username`'},
            {{mechanism = 'PLAIN', username = 'u\0evil', password = 'p'}, 'Startup failed: PLAIN authcid must not contain NUL'},
            {{mechanism = 'NONESUCH'}, 'Startup failed: NONESUCH unknown mechanism'},
        } do
            run(c[1], {})
            expect(statuses[#statuses] == c[2], 'logged ' .. c[2] .. ', got ' .. tostring(statuses[#statuses]))
        end
    end

    ------------------------------------------------------------------------
    -- failure numerics end the exchange instead of hanging

    for _, n in ipairs{N.ERR_SASLFAIL, N.ERR_SASLABORTED, N.ERR_NICKLOCKED,
                       N.ERR_SASLTOOLONG, N.ERR_SASLALREADY} do
        local ok, drained = run({mechanism = 'EXTERNAL'}, {numeric(n)})
        expect(ok == false and drained, 'numeric ' .. n .. ' is a failure')
    end

    ------------------------------------------------------------------------
    -- malformed server input aborts rather than throwing

    -- mybase64 skips characters outside the alphabet, so the payload that
    -- fails to decode is one with a dangling sextet
    do
        local ok = run({mechanism = 'PLAIN', username = 'u', password = 'p'},
            {auth 'A', numeric(N.ERR_SASLABORTED)})
        expect(ok == false, 'bad base64 fails')
        expect(sent[#sent] == 'AUTHENTICATE *', 'bad base64 aborts exchange')

        ok = run({mechanism = 'PLAIN', username = 'u', password = 'p'},
            {{command = 'AUTHENTICATE'}, numeric(N.ERR_SASLABORTED)})
        expect(ok == false and sent[#sent] == 'AUTHENTICATE *', 'missing argument aborts')

        -- an aborted exchange can't be rescued by a later 903
        ok = run({mechanism = 'PLAIN', username = 'u', password = 'p'},
            {auth 'A', numeric(N.RPL_SASLSUCCESS)})
        expect(ok == false, '903 after abort is not success')
    end

    -- unbounded server payloads are cut off
    do
        local chunk = ('A'):rep(400)
        local script = {}
        for i = 1, 200 do script[i] = auth(chunk) end
        script[#script + 1] = numeric(N.ERR_SASLABORTED)
        local ok = run({mechanism = 'EXTERNAL'}, script)
        expect(ok == false, 'oversize payload fails')
    end

    ------------------------------------------------------------------------
    -- SCRAM: server errors are failures, even if a 903 follows

    do
        local nonce = 'clientnonce'
        local server_first = 'r=' .. nonce .. 'servernonce1234,s=QSXCR+Q6sek8bf92,i=4096'

        -- error in server-first
        local ok = run({mechanism = 'SCRAM-SHA-1', username = 'u', password = 'p'},
            {auth '+', auth(mybase64.to_base64('e=unknown-user')), numeric(N.RPL_SASLSUCCESS)})
        expect(ok == false, 'server-first error followed by 903 is not success')

        -- the normal case: e= followed by the server's own 904; we send no abort
        ok = run({mechanism = 'SCRAM-SHA-1', username = 'u', password = 'p'},
            {auth '+', auth(mybase64.to_base64('e=unknown-user')), numeric(N.ERR_SASLFAIL)})
        expect(ok == false, 'server-first error then 904 fails')
        for _, line in ipairs(sent) do
            expect(line ~= 'AUTHENTICATE *', 'no abort sent after a server-reported error')
        end

        -- error in server-final: drive the mechanism directly
        local scram = require 'hub.net.sasl.scram'
        local co = scram('sha1', nil, 'u', 'p', nonce)
        assert(coroutine.resume(co))
        assert(coroutine.resume(co, server_first))
        local good, err = coroutine.resume(co, 'e=invalid-proof')
        expect(not good and type(err) == 'table' and err.server_error == 'invalid-proof',
            'server-final error raises a server_error')
        expect(coroutine.status(co) == 'dead', 'dead after error')

        -- bad server signature is an error
        co = scram('sha1', nil, 'u', 'p', nonce)
        assert(coroutine.resume(co))
        assert(coroutine.resume(co, server_first))
        good = coroutine.resume(co, 'v=' .. mybase64.to_base64(('z'):rep(20)))
        expect(not good, 'bad server signature raises')
    end

    ------------------------------------------------------------------------
    -- ANONYMOUS goes through SASLprep when available

    do
        local seen
        mystringprep = {stringprep = function(s, profile) seen = profile; return s end}
        local co = require 'hub.net.sasl.anonymous' ('trace')
        local _, msg = coroutine.resume(co)
        mystringprep = real_mystringprep
        expect(msg == 'trace' and seen == 'trace', 'anonymous uses stringprep(trace)')
    end

    -- SASLprep takes C strings; a NUL must fail rather than truncate.
    -- SCRAM has no NUL check of its own, so this is its only guard.
    if real_mystringprep then
        expect(not pcall(real_mystringprep.stringprep, 'p\0q', 'SASLprep'), 'stringprep rejects NUL')
        local ok = run({mechanism = 'SCRAM-SHA-256', username = 'u', password = 'p\0q'}, {})
        expect(ok == false, 'SCRAM password with NUL rejected')
        expect(#sent == 0, 'nothing sent when SCRAM startup fails')
    end

    ------------------------------------------------------------------------
    -- ECDH key loading: PEM (decrypted with the password), store, raw base64

    do
        local calls = {}
        local key = {export = function() return {pub = ('p'):rep(32)} end}
        stub_myopenssl {
            read_pem = function(...) calls[#calls + 1] = {'pem', ...}; return key end,
            pkey_from_store = function(...) calls[#calls + 1] = {'store', ...}; return key end,
            read_raw = function(...) calls[#calls + 1] = {'raw', ...}; return key end,
        }

        local pem = '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n'
        run({mechanism = 'ECDH-X25519-CHALLENGE', username = 'u', key = pem, password = 'pw'}, {numeric(N.ERR_SASLFAIL)})
        expect(calls[1][1] == 'pem' and calls[1][2] == pem and calls[1][4] == 'pw', 'PEM decrypted with password')

        calls = {}
        run({mechanism = 'ECDH-X25519-CHALLENGE', username = 'u', key = {store = 'store:x'}, password = 'pw'}, {numeric(N.ERR_SASLFAIL)})
        expect(calls[1][1] == 'store' and calls[1][2] == 'store:x' and calls[1][4] == 'pw', 'store key with password')

        calls = {}
        local raw = mybase64.to_base64(('k'):rep(32))
        run({mechanism = 'ECDH-X25519-CHALLENGE', username = 'u', key = raw}, {numeric(N.ERR_SASLFAIL)})
        expect(calls[1][1] == 'raw' and calls[1][4] == ('k'):rep(32), 'raw base64 key')

        local ok = run({mechanism = 'ECDH-X25519-CHALLENGE', username = 'u'}, {})
        expect(ok == false, 'key is required')
        myopenssl = real_myopenssl
    end

    ------------------------------------------------------------------------
    -- ECDSA key loading

    do
        local calls = {}
        local key = {sign = function() return 'sig' end}
        stub_myopenssl {
            read_pem = function(...) calls[#calls + 1] = {'pem', ...}; return key end,
            pkey_from_store = function(...) calls[#calls + 1] = {'store', ...}; return key end,
        }

        run({mechanism = 'ECDSA-NIST256P-CHALLENGE', username = 'u', key = {store = 'pkcs11:token=x'}, password = 'pw'},
            {numeric(N.ERR_SASLFAIL)})
        expect(calls[1] and calls[1][1] == 'store' and calls[1][2] == 'pkcs11:token=x' and calls[1][4] == 'pw',
            'ECDSA use_store loads from the store with the password')

        calls = {}
        run({mechanism = 'ECDSA-NIST256P-CHALLENGE', username = 'u', key = 'key.pem', password = 'pw'},
            {numeric(N.ERR_SASLFAIL)})
        expect(calls[1] and calls[1][1] == 'pem' and calls[1][4] == 'pw', 'ECDSA PEM decrypted with password')
        myopenssl = real_myopenssl
    end

    ------------------------------------------------------------------------
    -- The digest binding: hmac(data, key), as RFC 4231 case 1 shows

    do
        local sha256 = real_myopenssl.get_digest 'sha256'
        local mac = sha256:hmac('Hi There', ('\x0b'):rep(20))
        expect(mac:gsub('.', function(c) return string.format('%02x', c:byte()) end)
            == 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7', 'HMAC-SHA256 vector')
    end

    ------------------------------------------------------------------------
    -- ECDH-X25519-CHALLENGE: the response unmasks the server's challenge.
    -- The server's side is worked out here from the mechanism's definition:
    --   IKM = SHA256(shared || client public || server public)
    --   PRK = HMAC-SHA256(key = salt, IKM)
    --   OKM = HMAC-SHA256(key = PRK, "ECDH-X25519-CHALLENGE" 0x01)
    --   masked = challenge XOR OKM

    do
        local ossl = real_myopenssl
        local sha256 = ossl.get_digest 'sha256'
        local client = ossl.gen_pkey 'X25519'
        local server = ossl.gen_pkey 'X25519'
        local client_pub, server_pub = client:export().pub, server:export().pub
        local salt, challenge = ('s'):rep(32), ('c'):rep(31) .. 'C'

        local shared = server:derive(ossl.read_raw(ossl.types.EVP_PKEY_X25519, false, client_pub))
        local prk = sha256:hmac(sha256:digest(shared .. client_pub .. server_pub), salt)
        local okm = sha256:hmac('ECDH-X25519-CHALLENGE\1', prk)
        local masked = ossl.xor(challenge, okm)

        local co = require 'hub.net.sasl.ecdh' ('admin', 'user', client)
        local _, first = coroutine.resume(co)
        expect(first == 'user\0admin', 'authcid, then NUL and authzid')
        local ok, response = coroutine.resume(co, server_pub .. salt .. masked)
        expect(ok and response == challenge, 'the response is the challenge')

        co = require 'hub.net.sasl.ecdh' (nil, 'user', client)
        _, first = coroutine.resume(co)
        expect(first == 'user', 'no authzid')
        ok = coroutine.resume(co, ('x'):rep(95))
        expect(not ok, 'a server response of the wrong length fails')
    end

    ------------------------------------------------------------------------
    -- ECDSA-NIST256P-CHALLENGE: the response is a signature of the challenge

    do
        local key = real_myopenssl.gen_pkey('EC', 'P-256')
        local co = require 'hub.net.sasl.ecdsa' (nil, 'user', key)
        local _, first = coroutine.resume(co)
        expect(first == 'user', 'authcid')
        local ok, signature = coroutine.resume(co, 'the challenge')
        expect(ok and key:verify(signature, 'the challenge'), 'a signature the key verifies')
        expect(not key:verify(signature, 'another challenge'), 'of that challenge only')
    end

end

print('ok')
