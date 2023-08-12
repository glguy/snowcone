-- Logic for IRC messages
local tablex      = require 'pl.tablex'

local N           = require_ 'utils.numerics'
local challenge   = require_ 'utils.challenge'
local sasl        = require_ 'sasl'
local send        = require_ 'utils.send'
local split_nuh   = require_ 'utils.split_nick_user_host'

-- irc_state
-- .caps_ls        - set of string   - create in LS - consume at end of LS
-- .caps_list      - array of string - list of enabled caps - consume after LIST
-- .caps_wanted    - set of string   - create before LS - consume after ACK/NAK
-- .caps_enabled   - set of string   - filled by ACK
-- .caps_requested - set of string   - create on LS or NEW - consume at ACK or NAK
-- .want_sasl      - boolean         - consume at ACK to trigger SASL session
-- .phase          - string          - registration or connected
-- .sasl           - coroutine       - AUTHENTICATE state machine
-- .nick           - string          - current nickname
-- .target_nick    - string          - consumed when target nick recovered
-- .authenticate   - array of string - accumulated chunks of AUTHENTICATE
-- .challenge      - array of string - accumulated chunks of CHALLENGE

local function parse_source(source)
    return string.match(source, '^(.-)!(.-)@(.*)$')
end

local M = {}

function M.ERROR()
    irc_state.phase = 'closed'
end

function M.PING(irc)
    send('PONG', irc[1])
end

local ctcp_handlers = require_ 'handlers.ctcp'
function M.PRIVMSG(irc)
    local target, message = irc[1], irc[2]
    local ctcp, ctcp_args = message:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'
    if ctcp and target == irc_state.nick and irc.tags['solanum.chat/oper'] then
        ctcp = ctcp:upper()
        local nick = split_nuh(irc.source)
        local h = ctcp_handlers[ctcp]
        if h then
            local response = h(ctcp_args)
            if response then
                send('NOTICE', nick, '\x01' .. ctcp .. ' ' .. response .. '\x01')
            end
        end
    end
end

local cap_cmds = require_ 'handlers.cap'
function M.CAP(irc)
    -- irc[1] is a nickname or *
    local h = cap_cmds[irc[2]]
    if h then
        h(table.unpack(irc, 3))
    end
end

function M.NICK(irc)
    local nick = parse_source(irc.source)
    if nick and nick == irc_state.nick then
        irc_state.nick = irc[1]
        if irc_state.target_nick == irc_state.nick then
            irc_state.target_nick = nil
        end
    end
end

function M.AUTHENTICATE(irc)
    if not irc_state.sasl then
        status('sasl', 'no sasl session active')
        return
    end

    local chunk = irc[1]
    if chunk == '+' then
        chunk = ''
    end

    if irc_state.authenticate == nil then
        irc_state.authenticate = {chunk}
    else
        table.insert(irc_state.authenticate, chunk)
    end

    if #chunk < 400 then
        local payload = snowcone.from_base64(table.concat(irc_state.authenticate))
        irc_state.authenticate = nil

        local reply, secret
        if payload == nil then
            status('sasl', 'bad authenticate base64')
            -- discard the current sasl coroutine but still react
            -- to sasl reply codes
            irc_state.sasl = false
        else
            local success, message
            success, message, secret = coroutine.resume(irc_state.sasl, payload)
            if success then
                reply = message
            else
                status('sasl', '%s', message)
                irc_state.sasl = false
            end
        end

        sasl.authenticate(reply, secret)
    end
end

function M.BATCH(irc)
    local polarity = irc[1]:sub(1,1)
    local name = irc[1]:sub(2)
    if '+' == polarity then
        irc_state.batches[name] = tablex.sub(irc, 2)
    elseif '-' == polarity then
        irc_state.batches[name] = nil
    end
end

M[N.RPL_WELCOME] = function(irc)
    irc_state.phase = 'connected'
    irc_state.nick = irc[1]
    status('irc', 'connected to %s', irc.source)

    if configuration.irc_oper_username and configuration.irc_challenge_key then
        challenge.start()
    elseif configuration.irc_oper_username and configuration.irc_oper_password then
        send('OPER', configuration.irc_oper_username,
            {content=configuration.irc_oper_password, secret=true})
    else
        irc_state.oper = true
    end
end

M[N.RPL_ISUPPORT] = function(irc)
    local isupport = irc_state.isupport
    if isupport == nil then
        isupport = {}
        irc_state.isupport = isupport
    end

    for i = 2, #irc - 1 do
        local token = irc[i]
        local minus, key, equals, val = string.match(token, '^(%-?)(%w+)(=?)(.*)$')
        if minus == '-' then
            isupport[key] = nil
        elseif equals == '' then
            isupport[key] = true
        else
            isupport[key] = val
        end
    end
end

M[N.RPL_SNOMASK] = function(irc)
    status('irc', 'snomask %s', irc[2])
end

M[N.ERR_NOOPERHOST] = function()
    challenge.fail('no oper host')
end

M[N.ERR_PASSWDMISMATCH] = function()
    challenge.fail('oper password mismatch')
end

M[N.RPL_RSACHALLENGE2] = function(irc)
    challenge.add_chunk(irc[2])
end

M[N.RPL_ENDOFRSACHALLENGE2] = function()
    challenge.response()
end

M[N.RPL_YOUREOPER] = function()
    irc_state.oper = true
    send('MODE', irc_state.nick, 's', 'BFZbcklnsx')
    status('irc', "you're oper")
end

M[N.RPL_SASLSUCCESS] = function()
    if irc_state.sasl then
        status('irc', 'SASL success')
        irc_state.sasl = nil

        if irc_state.phase == 'registration' then
            send('CAP', 'END')
        end
    end
end

M[N.ERR_SASLFAIL] = function()
    if irc_state.sasl ~= nil then
        status('irc', 'SASL failed')
        irc_state.sasl = nil
        disconnect()
    end
end

M[N.ERR_SASLABORTED] = function()
    if irc_state.sasl ~= nil then
        irc_state.sasl = nil
        disconnect()
    end
end

M[N.RPL_SASLMECHS] = function()
    if irc_state.sasl then
        status('irc', 'bad SASL mechanism')
        irc_state.sasl = nil
        disconnect()
    end
end

local function new_nickname()
    if irc_state.phase == 'registration' then
        local nick = string.format('%.10s-%05d', configuration.irc_nick, math.random(0,99999))
        irc_state.target_nick = configuration.irc_nick
        send('NICK', nick)
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

return M
