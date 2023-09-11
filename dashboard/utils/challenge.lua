local Set  = require 'pl.Set'
local N    = require 'utils.numerics'
local send = require 'utils.send'

local commands1 = Set{
    N.ERR_NOOPERHOST,
    N.RPL_RSACHALLENGE2,
    N.RPL_ENDOFRSACHALLENGE2,
    N.RPL_YOUREOPER,
}

local commands2 = Set{
    N.RPL_YOUREOPER,
    N.ERR_PASSWDMISMATCH,
    N.ERR_NOOPERHOST,
}

return function(task)
    local file    = require 'pl.file'

    -- make sure we have a username and a key before bothering the server
    local user    = assert(configuration.oper_username, 'missing oper_username')
    local path    = assert(configuration.challenge_key, 'missing challenge_key')
    local rsa_key = assert(file.read(path))
    local key     = assert(myopenssl.read_pkey(rsa_key, true, configuration.challenge_password))

    local n = 0
    local chunks = {}

    send('CHALLENGE', user)
    while true do
        local irc = task:wait_irc(commands1)
        local command = irc.command
        if command == N.RPL_RSACHALLENGE2 then
            n = n + 1
            chunks[n] = irc[2]
        elseif command == N.RPL_ENDOFRSACHALLENGE2 then
            break
        elseif command == N.RPL_YOUREOPER then
            status('challenge', 'already oper')
            return
        elseif command == N.ERR_NOOPERHOST then
            status('challenge', 'host mismatch')
            return
        end
    end

    local input    = table.concat(chunks)
    local envelope = assert(snowcone.from_base64(input), 'bad base64')
    local message  = assert(key:decrypt(envelope, 'oaep'))
    local digest   = myopenssl.get_digest('sha1'):digest(message)
    local response = snowcone.to_base64(digest)

    send('CHALLENGE', '+' .. response)
    local irc = task:wait_irc(commands2)
    local command = irc.command
    if command == N.RPL_YOUREOPER then
        status('challenge', "oper up")
    elseif command == N.ERR_PASSWDMISMATCH then
        status('challenge', 'key mismatch')
    elseif command == N.ERR_NOOPERHOST then
        status('challenge', 'host mismatch')
    end
end
