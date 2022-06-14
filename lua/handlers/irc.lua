-- Logic for IRC messages
local Set         = require 'pl.Set'
local N           = require_ 'utils.numerics'
local challenge   = require_ 'utils.challenge'
local sasl        = require_ 'sasl'
local parse_snote = require_ 'utils.parse_snote'
local send        = require 'utils.send'

local function parse_source(source)
    return string.match(source, '^(.-)!(.-)@(.*)$')
end

local M = {}

function M.ERROR()
    irc_state.connected = nil
end

function M.PING(irc)
    send('PONG', irc[1])
end

local handlers = require_ 'handlers.snotice'
function M.NOTICE(irc)
    if irc[1] == '*' and not string.match(irc.source, '@') then
        local note = string.match(irc[2], '^%*%*%* Notice %-%- (.*)$')
        if note then
            local event = parse_snote(irc.time, irc.source, note)
            if event then
                local handled = false

                local h = handlers[event.name]
                if h then
                    h(event)
                    handled = true
                end

                for _, plugin in ipairs(plugins) do
                    h = plugin.snotice
                    if h then
                        local success, err = pcall(h, event)
                        if not success then
                            status(plugin.name, 'snotice handler error: ' .. tostring(err))
                        end
                        handled = true
                    end
                end

                if handled and views[view].active then
                    draw()
                end
            end
        end
    end
end

M.NICK = function(irc)
    local nick = parse_source(irc.source)
    if nick and nick == irc_state.nick then
        irc_state.nick = irc[1]
        if irc_state.target_nick == irc_state.nick then
            irc_state.target_nick = nil
        end
    end
end

M.AUTHENTICATE = function(irc)
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
        local reply

        local full = table.concat(irc_state.authenticate)
        irc_state.authenticate = nil
        local payload = snowcone.from_base64(full)

        if payload == nil then
            status('sasl', 'bad authenticate base64')
        elseif irc_state.sasl == nil then
            status('sasl', 'no sasl session active')
        else
            local success, message = coroutine.resume(irc_state.sasl, payload)
            if success then
                reply = message
            else
                status('sasl', '%s', message)
            end
        end

        for _, cmd in ipairs(sasl.encode_authenticate(reply)) do
            send(table.unpack(cmd))
        end
    end
end

M[N.RPL_WELCOME] = function(irc)
    irc_state.registration = nil
    irc_state.connected = true
    status('irc', 'connected to %s', irc.source)

    if configuration.irc_oper_username and configuration.irc_challenge_key then
        send('CHALLENGE', configuration.irc_oper_username)
        irc_state.challenge = {}
    elseif configuration.irc_oper_username and configuration.irc_oper_password then
        send('OPER', configuration.irc_oper_username,
            {content=configuration.irc_oper_password, secret=true})
    else
        irc_state.oper = true
        snowcone.send_irc(counter_sync_commands())
    end
    snowcone.reset_delay()
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

M[N.RPL_NOTESTLINE] = function()
    if staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action = nil
    end
end

M[N.RPL_TESTLINE] = function(irc)
    if irc[2] == 'k'
    and staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action.mask = irc[4]
    end
end

M[N.RPL_TESTMASKGECOS] = function(irc)
    local loc, rem, mask, gecos = table.unpack(irc,2,5)
    local total = math.tointeger(loc) + math.tointeger(rem)
    if staged_action and '*' == gecos and '*!'..staged_action.mask == mask then
        staged_action.count = total
    end
    if gecos == '*' and mask:startswith '*!*@' then
        local label = string.sub(mask, 5)
        for _, entry in pairs(net_trackers) do
            entry:set(label, total)
        end
    end
end

M[N.RPL_MAP] = function(irc)
    if not irc_state.in_map then
        population = {}
        irc_state.in_map = true
    end

    local server, count = string.match(irc[2], '(%g*)%[...%] %-* | Users: +(%d+)')
    if server then
        population[server] = math.tointeger(count)
    end
end

M[N.RPL_MAPEND] = function()
    irc_state.in_map = nil
end

M[N.RPL_VERSION] = function(irc)
    versions[irc.source] = string.match(irc[2] or '', '%((.*)%)')
end

M[N.RPL_LINKS] = function(irc)
    if not irc_state.links then
        irc_state.links = {}
    end

    local server, linked = table.unpack(irc, 2, 3)
    irc_state.links[server] = Set{linked}
    if irc_state.links[linked] then
        irc_state.links[linked][server] = true
    end
end

M[N.RPL_ENDOFLINKS] = function()
    links = irc_state.links
    irc_state.links = nil

    local primary_hub = servers.primary_hub
    if primary_hub then
        upstream = {[primary_hub] = primary_hub}
        local q = {primary_hub}
        for _, here in ipairs(q) do
            for k, _ in pairs(links[here] or {}) do
                if not upstream[k] then
                    upstream[k] = here
                    table.insert(q, k)
                end
            end
        end
    end
end

M[N.RPL_STATSUPTIME] = function(irc)
    local days, h, m, s = string.match(irc[2], ' (%d+) days, (%d+):(%d+):(%d+)$')
    local now = os.time()
    local startup = now - 86400 * days - 3600 * h - 60 * m - s
    local text = os.date('!%Y-%m-%d %H:%M:%S', startup)
    uptimes[irc.source] = text
end

M[N.ERR_NOOPERHOST] = function()
    irc_state.challenge = nil
    status('irc', 'no oper host')
end

M[N.ERR_PASSWDMISMATCH] = function()
    irc_state.challenge = nil
    status('irc', 'oper password mismatch')
end

M[N.RPL_RSACHALLENGE2] = function(irc)
    local challenge_text = irc_state.challenge
    if challenge_text then
        table.insert(challenge_text, irc[2])
    end
end

M[N.RPL_ENDOFRSACHALLENGE2] = function()
    -- remember and clear the challenge buffer now before failures below
    local challenge_text = irc_state.challenge
    if challenge_text then
        irc_state.challenge = nil
        challenge_text = table.concat(challenge_text)

        local file          = require 'pl.file'
        local rsa_key       = assert(file.read(configuration.irc_challenge_key))
        local password      = configuration.irc_challenge_password
        local success, resp = pcall(challenge, rsa_key, password, challenge_text)
        if success then
            send('CHALLENGE',  '+' .. resp)
            status('irc', 'challenged')
        else
            io.stderr:write(resp,'\n')
            status('irc', 'challenge failed - see stderr')
        end
    end
end

M[N.RPL_YOUREOPER] = function()
    irc_state.oper = true
    snowcone.send_irc(counter_sync_commands())
    send('MODE', irc_state.nick, 's', 'BFZbcklnsx')
    status('irc', "you're oper")
end

M[N.RPL_SASLSUCCESS] = function()
    if irc_state.sasl then
        status('irc', 'SASL success')
        irc_state.sasl = nil

        if irc_state.registration then
            send('CAP', 'END')
        end
    end
end

M[N.ERR_SASLFAIL] = function()
    if irc_state.sasl then
        status('irc', 'SASL failed')
        irc_state.sasl = nil
        send('QUIT')
        snowcone.send_irc(nil)
    end
end

M[N.ERR_SASLABORTED] = function()
    if irc_state.sasl then
        irc_state.sasl = nil
        send('QUIT')
        snowcone.send_irc(nil)
    end
end

M[N.RPL_SASLMECHS] = function()
    if irc_state.sasl then
        status('irc', 'bad SASL mechanism')
        irc_state.sasl = nil
        send('QUIT')
        snowcone.send_irc(nil)
    end
end

local function new_nickname()
    if irc_state.registration then
        local nick = string.format('%.10s-%05d', configuration.irc_nick, math.random(0,99999))
        irc_state.nick = nick
        irc_state.target_nick = configuration.irc_nick
        send('NICK', nick)
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

return M
