-- Solanum CHALLENGE operator authentication (from ircc/utils/challenge.lua,
-- the superset of the two copies: it adds use_store). Runs in a network task.

local N       <const> = require 'hub.lib.numerics'
local secrets <const> = require 'hub.runtime.secrets'

local commands1 <const> = {
    N.ERR_NOOPERHOST,
    N.RPL_RSACHALLENGE2,
    N.RPL_ENDOFRSACHALLENGE2,
    N.RPL_YOUREOPER,
}

local commands2 <const> = {
    N.RPL_YOUREOPER,
    N.ERR_PASSWDMISMATCH,
    N.ERR_NOOPERHOST,
}

---@param t table network task
---@param cfg table the network's `challenge` section
return function(t, cfg)
    -- make sure we have a username and a key before bothering the server
    local user <const> = assert(cfg.username, 'missing challenge.username')
    local rsa_pem <const> = assert(secrets.resolve(t, cfg.key), 'missing challenge.key')
    local password <const> = secrets.resolve(t, cfg.password)
    local key
    if cfg.use_store then
        key = myopenssl.pkey_from_store(rsa_pem, true, password)
    else
        key = myopenssl.read_pem(rsa_pem, true, password)
    end

    local n = 0
    local chunks <const> = {}

    t:send('CHALLENGE', user)
    while true do
        local msg     <const> = t:wait_irc(commands1)
        local command <const> = msg.command
        if command == N.RPL_RSACHALLENGE2 then
            n = n + 1
            chunks[n] = msg[2]
        elseif command == N.RPL_ENDOFRSACHALLENGE2 then
            break
        elseif command == N.RPL_YOUREOPER then
            t:log('challenge', 'already oper')
            return
        elseif command == N.ERR_NOOPERHOST then
            t:log('challenge', 'host mismatch')
            return
        end
    end

    local input    <const> = table.concat(chunks)
    local envelope <const> = assert(mybase64.from_base64(input), 'bad base64')
    local message  <const> = assert(key:decrypt(envelope, 'oaep'))
    local digest   <const> = myopenssl.get_digest('sha1'):digest(message)
    local response <const> = mybase64.to_base64(digest)

    t:send('CHALLENGE', '+' .. response)
    local msg     <const> = t:wait_irc(commands2)
    local command <const> = msg.command
    if command == N.RPL_YOUREOPER then
        t:log('challenge', 'oper up')
    elseif command == N.ERR_PASSWDMISMATCH then
        t:log('challenge', 'key mismatch')
    elseif command == N.ERR_NOOPERHOST then
        t:log('challenge', 'host mismatch')
    end
end
