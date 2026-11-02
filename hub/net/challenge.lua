-- CHALLENGE operator authentication, as the network's ircd does it. Runs
-- in a network task.
--
-- Solanum sends the challenge base64 in RPL_RSACHALLENGE2 lines, OAEP
-- padded, and wants the base64 SHA-1 of the secret. OFTC hybrid sends it
-- hex in one RPL_RSACHALLENGE, PKCS#1 v1.5 padded, and wants the secret
-- in hex.

local check   <const> = require 'hub.lib.check'
local ircd    <const> = require 'hub.net.ircd'
local N       <const> = require 'hub.lib.numerics'
local secrets <const> = require 'hub.runtime.secrets'

local commands1 <const> = {
    N.ERR_NOOPERHOST,
    N.RPL_RSACHALLENGE2,
    N.RPL_ENDOFRSACHALLENGE2,
    N.RPL_YOUREOPER,
}

local hybrid_commands1 <const> = {
    N.ERR_NOOPERHOST,
    N.RPL_RSACHALLENGE,
    N.RPL_YOUREOPER,
    'NOTICE',
}

local hybrid_commands2 <const> = {
    N.RPL_YOUREOPER,
    N.ERR_PASSWDMISMATCH,
    N.ERR_NOOPERHOST,
    'NOTICE',
}

-- OFTC hybrid's failures that come as a NOTICE from the server, by text,
-- and what to log for them
local hybrid_notices <const> = {
    ["I'm sorry, PK authentication is not enabled for your oper{} block."] = 'no key in the oper block',
    ["Can't attach conf!"] = "the server can't attach the oper block",
}

-- What a NOTICE from the server says went wrong, or nil for another one
local function hybrid_failure(msg)
    if msg.command == 'NOTICE' and msg.source and not msg.source:find '[!@]' then
        return hybrid_notices[msg[2]]
    end
end

local commands2 <const> = {
    N.RPL_YOUREOPER,
    N.ERR_PASSWDMISMATCH,
    N.ERR_NOOPERHOST,
}

-- The response to Solanum's challenge, or nil after logging why not
local function solanum_response(t, user, key)
    local n = 0
    local chunks <const> = {}

    local ended
    for msg in t:request(commands1, 30000, 'CHALLENGE', user) do
        local command <const> = msg.command
        if command == N.RPL_RSACHALLENGE2 then
            n = n + 1
            chunks[n] = msg[2]
        elseif command == N.RPL_ENDOFRSACHALLENGE2 then
            ended = true
            break
        elseif command == N.RPL_YOUREOPER then
            t:log('challenge', 'already oper')
            return nil, true
        elseif command == N.ERR_NOOPERHOST then
            t:log('challenge', 'host mismatch')
            return
        end
    end
    if not ended then
        t:log('challenge', 'no challenge from the server')
        return
    end

    local input    <const> = table.concat(chunks)
    local envelope <const> = check(mybase64.from_base64(input), 'bad base64 in the challenge from the server')
    local message  <const> = key:decrypt(envelope, 'oaep')
    local digest   <const> = myopenssl.get_digest('sha1'):digest(message)
    return mybase64.to_base64(digest)
end

-- The response to OFTC hybrid's challenge, or nil after logging why not
local function hybrid_response(t, user, key)
    local msg
    for reply in t:request(hybrid_commands1, 30000, 'CHALLENGE', user) do
        local failure = hybrid_failure(reply)
        if failure then
            t:log('challenge', '%s', failure)
            return
        elseif reply.command ~= 'NOTICE' then
            msg = reply
            break
        end
    end
    local command <const> = msg and msg.command
    if command == N.RPL_YOUREOPER then
        t:log('challenge', 'already oper')
        return nil, true
    elseif command == N.ERR_NOOPERHOST then
        t:log('challenge', 'host mismatch')
        return
    elseif command ~= N.RPL_RSACHALLENGE then
        t:log('challenge', 'no challenge from the server')
        return
    end

    local hex <const> = msg[2] or ''
    check(#hex % 2 == 0 and not hex:find '%X', 'bad hex in the challenge from the server')
    local envelope <const> = hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end)
    local secret <const> = key:decrypt(envelope)
    return (secret:gsub('.', function(c) return string.format('%02X', string.byte(c)) end))
end

---@param t hub.Task
---@param cfg table an `oper.credentials` entry with mechanism 'challenge'
---@return boolean # we are an operator
return function(t, cfg)
    -- make sure we have a username and a key before bothering the server
    local user <const> = assert(cfg.username, 'missing username')
    local store <const> = secrets.key_store(cfg.key)
    local password <const> = secrets.resolve(t, cfg.password)
    local key
    if store then
        key = myopenssl.pkey_from_store(store, true, password)
    else
        local rsa_pem <const> = assert(secrets.resolve(t, cfg.key), 'missing key')
        key = myopenssl.read_pem(rsa_pem, true, password)
    end

    local response, already
    if ircd.hybrid(t.net) then
        response, already = hybrid_response(t, user, key)
    else
        response, already = solanum_response(t, user, key)
    end
    if not response then return already == true end

    -- the first reply that matters is the answer
    local hybrid <const> = ircd.hybrid(t.net)
    local msg
    for reply in t:request(hybrid and hybrid_commands2 or commands2, 30000, 'CHALLENGE',
        {content = '+' .. response, secret = true})
    do
        local failure = hybrid and hybrid_failure(reply)
        if failure then
            t:log('challenge', '%s', failure)
            return false
        elseif reply.command ~= 'NOTICE' then
            msg = reply
            break
        end
    end
    local command <const> = msg and msg.command
    if command == nil then
        t:log('challenge', 'no answer to the challenge response')
    elseif command == N.RPL_YOUREOPER then
        t:log('challenge', 'oper up')
        return true
    elseif command == N.ERR_PASSWDMISMATCH then
        t:log('challenge', 'key mismatch')
    elseif command == N.ERR_NOOPERHOST then
        t:log('challenge', 'host mismatch')
    end
    return false
end
