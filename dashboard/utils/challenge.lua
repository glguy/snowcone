local send = require 'utils.send'

local M = {}

function M.start()
    local file          = require 'pl.file'

    -- make sure we have a username and a key before bothering the server
    local user          = assert(configuration.oper_username, 'missing oper_username')
    local rsa_key       = assert(file.read(configuration.challenge_key))
    local key           = assert(myopenssl.readpkey(rsa_key, true, 'pem', configuration.challenge_password))

    irc_state.challenge_key = key
    irc_state.challenge = {}
    send('CHALLENGE', user)
end

function M.add_chunk(chunk)
    local challenge_text = irc_state.challenge
    if challenge_text then
        table.insert(challenge_text, chunk)
    end
end

function M.fail(...)
    if irc_state.challenge then
        irc_state.challenge_key = nil
        irc_state.challenge = nil
        status('challenge', ...)
    end
end

function M.response()
    if irc_state.challenge then
        local sha1 = myopenssl.getdigest 'sha1'

        local key = irc_state.challenge_key
        local challenge = table.concat(irc_state.challenge)
        irc_state.challenge_key = nil
        irc_state.challenge = nil

        local envelope = assert(snowcone.from_base64(challenge), 'bad base64')
        local message  = assert(key:decrypt(envelope, 'oaep'))
        local digest   = sha1:digest(message)
        local response = snowcone.to_base64(digest)

        send('CHALLENGE', '+' .. response)
        status('irc', 'challenged')
    end
end

return M
