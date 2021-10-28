-- Logic for IRC messages

local M = {}

function M.ERROR()
    irc_state.connected = nil
end

function M.PING(irc)
    snowcone.send_irc('PONG :' .. irc[1] .. '\r\n')
end

local parse_snote = require_ 'parse_snote'
local handlers = require_ 'handlers.snotice'
function M.NOTICE(irc)
    if irc[1] == '*' and not string.match(irc.source, '@') then
        local note = string.match(irc[2], '^%*%*%* Notice %-%- (.*)$')
        if note then
            local time
            if irc.tags.time then
                time = string.match(irc.tags.time, '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d%d%dZ$')
            else
                time = os.date '!%H:%M:%S'
            end

            local event = parse_snote(time, irc.source, note)
            if event then
                local h = handlers[event.name]
                if h then
                    h(event)
                    if views[view].active then
                        draw()
                    end
                end
            end
        end
    end
end

M.NICK = function(irc)
    local nick = string.match(irc.source, '^(.-)!')
    if nick and nick == irc_state.nick then
        irc_state.nick = irc[1]
    end
    if irc_state.altnick and irc[1] == configuration.irc_nick then
        irc_state.altnick = nil
    end
end

M.AUTHENTICATE = function(irc)
    if irc_state.sasl then
        local payload = irc_authentication.decode_authenticate(irc[1])
        local success, message = coroutine.resume(irc_state.sasl, payload)
        if not success then
            message = nil
        end
        snowcone.send_irc(irc_authentication.encode_authenticate(message))
    end
end

-- RPL_WELCOME
M['001'] = function()
    irc_state.registration = nil
    irc_state.connected = true
    status_message = 'connected'

    local msg
    if configuration.irc_oper_username and configuration.irc_challenge_key then
        msg = 'CHALLENGE ' .. configuration.irc_oper_username .. '\r\n'
        irc_state.challenge = {}
    elseif configuration.irc_oper_username and configuration.irc_oper_password then
        msg = 'OPER ' ..
            configuration.irc_oper_username .. ' :' ..
            configuration.irc_oper_password .. '\r\n'
    else
        irc_state.oper = true
        msg = counter_sync_commands()
    end
    snowcone.send_irc(msg)
end

M['008'] = function(irc)
    status_message = 'snomask ' .. irc[2]
end

-- RPL_STATS_ILINE
M['215'] = function()
    if staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action = nil
    end
end

-- RPL_TESTLINE
M['725'] = function(irc)
    if irc[2] == 'k'
    and staged_action ~= nil
    and staged_action.action == 'unkline'
    and staged_action.mask == nil
    then
        staged_action.mask = irc[4]
    end
end

-- RPL_TESTMASK_GECOS
M['727'] = function(irc)
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

-- RPL_MAP
M['015'] = function(irc)
    if not irc_state.in_map then
        population = {}
        irc_state.in_map = true
    end

    local server, count = string.match(irc[2], '(%g*)%[...%] %-* | Users: +(%d+)')
    if server then
        population[server] = math.tointeger(count)
    end
end

-- RPL_MAPEND
M['017'] = function()
    irc_state.in_map = nil
end

-- RPL_VERSION
M['351'] = function(irc)
    versions[irc.source] = string.match(irc[2] or '', '%((.*)%)')
end

-- RPL_LINKS
M['364'] = function(irc)
    if not irc_state.links then
        irc_state.links = {}
    end

    local server, linked = table.unpack(irc, 2, 3)
    irc_state.links[server] = Set{linked}
    if irc_state.links[linked] then
        irc_state.links[linked][server] = true
    end
end

-- RPL_END_OF_LINKS
M['365'] = function()
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

-- ERR_ERR_NOOPERHOST
M['491'] = function()
    irc_state.challenge = nil
    status_message = 'no oper host'
end

-- ERR_PASSWDMISMATCH
M['464'] = function()
    irc_state.challenge = nil
    status_message = 'oper password mismatch'
end

-- RPL_RSACHALLENGE2
M['740'] = function(irc)
    local challenge = irc_state.challenge
    if challenge then
        table.insert(challenge, irc[2])
    end
end

-- RPL_ENDOFRSACHALLENGE2
M['741'] = function()
    -- remember and clear the challenge buffer now before failures below
    local challenge = irc_state.challenge
    if challenge then
        irc_state.challenge = nil
        challenge = table.concat(challenge)

        local file          = require 'pl.file'
        local rsa_key       = assert(file.read(configuration.irc_challenge_key))
        local password      = configuration.irc_challenge_password
        local success, resp = pcall(irc_authentication.challenge, rsa_key, password, challenge)
        if success then
            snowcone.send_irc('CHALLENGE +' .. resp .. '\r\n')
            status_message = 'challenged'
        else
            io.stderr:write(resp,'\n')
            status_message = 'challenge failed - see stderr'
        end
    end
end

-- RPL_YOUREOPER
M['381'] = function()
    irc_state.oper = true
    snowcone.send_irc(
        counter_sync_commands() ..
        'MODE ' .. irc_state.nick .. ' s BFZcknsx\r\n'
    )
    status_message = "you're oper"
end

-- RPL_SASLSUCCESS
M['903'] = function()
    if irc_state.sasl then
        status_message = 'SASL success'
        irc_state.sasl = nil

        if irc_state.in_cap then
            snowcone.send_irc 'CAP END\r\n'
            irc_state.in_cap = nil
        end
    end
end

-- ERR_SASLFAIL
M['904'] = function()
    if irc_state.sasl then
        status_message = 'SASL failed'
        irc_state.sasl = nil
        snowcone.send_irc 'QUIT\r\n'
    end
end

-- ERR_SASLABORTED
M['906'] = function()
    if irc_state.sasl then
        irc_state.sasl = nil
        snowcone.send_irc 'QUIT\r\n'
    end
end

-- RPL_SASLMECHS
M['908'] = function()
    if irc_state.sasl then
        status_message = 'bad SASL mechanism'
        irc_state.sasl = nil
        snowcone.send_irc 'QUIT\r\n'
    end
end

local function new_nickname()
    if irc_state.registration then
        local nick = string.format('%.10s-%05d', configuration.irc_nick, math.random(0,99999))
        irc_state.nick = nick
        irc_state.altnick = true
        snowcone.send_irc('NICK ' .. nick .. '\r\n')
    end
end

-- ERR_ERRONEUSNICKNAME
M['432'] = new_nickname
-- ERR_NICKNAMEINUSE
M['433'] = new_nickname
-- ERR_UNAVAILRESOURCE
M['437'] = new_nickname

return M
