local send = require 'utils.send'

local M = {}

function M.start()
    local openssl       = require 'openssl'
    local file          = require 'pl.file'
    
    -- make sure we have a username and a key before bothering the server
    local user          = assert(configuration.irc_oper_username, 'missing irc_oper_username')
    local rsa_key       = assert(file.read(configuration.irc_challenge_key))
    local key           = assert(openssl.pkey.read(rsa_key, true, 'auto', configuration.irc_challenge_password))

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
        local openssl = require 'openssl'
        local sha1 = openssl.digest.get 'sha1'

        local key = irc_state.challenge_key
        local challenge = table.concat(irc_state.challenge)
        irc_state.challenge_key = nil
        irc_state.challenge = nil

        local envelope = assert(openssl.base64(challenge, false, true), 'bad base64')
        local message  = assert(key:decrypt(envelope, 'oaep'))
        local digest   = sha1:digest(message)
        local response = openssl.base64(digest, true, true)

        send('CHALLENGE', '+' .. response)
        status('irc', 'challenged')
    end
end

return M