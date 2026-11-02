-- Becoming an operator with a credential from the network's `oper`
-- table: OPER with a password, or CHALLENGE with a key. Runs in a
-- network task.

local challenge <const> = require 'hub.net.challenge'
local N         <const> = require 'hub.lib.numerics'
local secrets   <const> = require 'hub.runtime.secrets'

local M = {}

local oper_replies <const> = {
    N.RPL_YOUREOPER,
    N.ERR_PASSWDMISMATCH,
    N.ERR_NOOPERHOST,
}

local function password_login(t, credential)
    local password <const> = secrets.resolve(t, credential.password)
    local msg <const> = t:request(oper_replies, 30000, 'OPER', credential.username,
        {content = password, secret = true})()
    local command <const> = msg and msg.command
    if command == N.RPL_YOUREOPER then
        t:log('oper', 'oper up')
        return true
    elseif command == N.ERR_PASSWDMISMATCH then
        t:log('oper', 'password mismatch')
    elseif command == N.ERR_NOOPERHOST then
        t:log('oper', 'host mismatch')
    else
        t:log('oper', 'no answer to OPER')
    end
    return false
end

--- Log in with one credential.
---@param t hub.Task
---@param credential table an `oper.credentials` entry
---@return boolean # we are an operator
function M.login(t, credential)
    if credential.mechanism == 'challenge' then
        return challenge(t, credential)
    end
    return password_login(t, credential)
end

--- Try credentials in order until one works.
---@param t hub.Task
---@param credentials table[] `oper.credentials` entries
---@return boolean # we are an operator
function M.first(t, credentials)
    for _, credential in ipairs(credentials) do
        if M.login(t, credential) then
            return true
        end
    end
    return false
end

return M
