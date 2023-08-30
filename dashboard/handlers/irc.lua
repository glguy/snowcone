-- Logic for IRC messages
local Set         = require 'pl.Set'
local N           = require_ 'utils.numerics'
local challenge   = require_ 'utils.challenge'
local sasl        = require_ 'sasl'
local parse_snote = require_ 'utils.parse_snote'
local send        = require 'utils.send'
local split_nuh   = require_ 'utils.split_nick_user_host'

-- irc_state
-- .caps_available - set of string   - create in LS - consume at end of LS
-- .caps_wanted    - set of string   - create before LS - consume after ACK/NAK
-- .caps_enabled   - set of string   - create before LS - consume at quit
-- .caps_list      - array of string - list of enabled caps - consume after LIST
-- .want_sasl      - boolean         - consume at ACK to trigger SASL session
-- .registration   - boolean         - create on connect - consume at 001
-- .connected      - boolean         - create on 001     - consume at ERROR
-- .sasl           - coroutine       - AUTHENTICATE state machine
-- .authenticate   - array of string - accumulated chunks of AUTHENTICATE
-- .nick           - string          - current nickname
-- .target_nick    - string          - consumed when target nick recovered

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

local ctcp_handlers = require_ 'handlers.ctcp'
function M.PRIVMSG(irc)
    local target, message = irc[1], irc[2]
    local ctcp, ctcp_args = message:match '^\x01(%S+) ?([^\x01]*)\x01?$'
    if ctcp and not target:startswith '#' and irc.tags['solanum.chat/oper'] then
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

local cap_cmds = require_ 'handlers.cap'
function M.CAP(irc)
    -- irc[1] is a nickname or *
    local h = cap_cmds[irc[2]]
    if h then
        h(table.unpack(irc, 3))
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

-- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
M[N.RPL_WELCOME] = function(irc)
    irc_state.nick = irc[1]
end

-- "<client> <1-13 tokens> :are supported by this server"
M[N.RPL_ISUPPORT] = function(irc)
    for i = 2, #irc - 1 do
        local token = irc[i]
        -- soju.im/bouncer-networks happens to add _ to the allowed characters
        local minus, key, equals, val = token:match '^(%-?)([%u%d_]+)(=?)(.*)$'
        if minus == '-' then
            val = nil
        elseif equals == '' then
            val = true
        end
        irc_state:set_isupport(key, val)
    end
end

local function end_of_registration()
    irc_state.phase = 'connected'
    status('irc', 'connected')

    if configuration.oper_username and configuration.challenge_key then
        challenge.start()
    elseif configuration.oper_username and configuration.oper_password then
        send('OPER', configuration.oper_username,
            {content=configuration.oper_password, secret=true})
    else
        -- determine if we're already oper
        send('MODE', irc_state.nick)
    end
end

-- "<client> :End of /MOTD command."
M[N.RPL_ENDOFMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
    end
end

-- "<client> :MOTD File is missing"
M[N.ERR_NOMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
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
        local rsa_key       = assert(file.read(configuration.challenge_key))
        local password      = configuration.challenge_password
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
    counter_sync_commands()
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

        if irc_state.phase == 'registration' then
            disconnect()
        end
    end
end

M[N.ERR_SASLABORTED] = function()
    if irc_state.sasl ~= nil then
        irc_state.sasl = nil

        if irc_state.phase == 'registration' then
            disconnect()
        end
    end
end

M[N.RPL_SASLMECHS] = function()
    if irc_state.sasl then
        status('irc', 'bad SASL mechanism')
        irc_state.sasl = nil

        if irc_state.phase == 'registration' then
            disconnect()
        end
    end
end

local function new_nickname()
    if irc_state.registration then
        local nick = string.format('%.10s-%05d', configuration.nick, math.random(0,99999))
        irc_state.nick = nick
        irc_state.target_nick = configuration.nick
        send('NICK', nick)
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

-- K-Line by nickname chase logic =====================================

M[N.RPL_WHOSPCRPL] = function(irc)
    if '696' == irc[2] then
        local nick = snowcone.irccase(irc[6])
        if irc_state.kline_hunt[nick] then
            prepare_kline(irc[6], irc[3], irc[5], irc[4])
            irc_state.kline_hunt[nick] = nil
        end
    end
end

M[N.RPL_ENDOFWHO] = function(irc)
    local nick = snowcone.irccase(irc[2])
    if irc_state.kline_hunt[nick] then
        send('WHOWAS', irc[2], 1)
    end
end

M[N.RPL_WHOWASUSER] = function(irc)
    local nick = snowcone.irccase(irc[2])
    local hunt = irc_state.kline_hunt[nick]
    if hunt then
        hunt.user = irc[3]
        hunt.host = irc[4]
        hunt.gecos = irc[6]
    end
end

M[N.ERR_WASNOSUCHNICK] = function(irc)
    local nick = snowcone.irccase(irc[2])
    local hunt = irc_state.kline_hunt[nick]
    if hunt then
        status('kline', 'Failed to find %s', irc[2])
        irc_state.kline_hunt[nick] = nil
    end
end

M[N.RPL_ENDOFWHOWAS] = function(irc)
    local nick = snowcone.irccase(irc[2])
    local hunt = irc_state.kline_hunt[nick]
    if hunt then
        if hunt.user and hunt.host and hunt.gecos then
            prepare_kline(irc[2], hunt.user, hunt.host, '255.255.255.255')
        else
            status('kline', 'Failed to find %s', irc[2])
        end
        irc_state.kline_hunt[nick] = nil
    end
end

M[N.RPL_WHOISACTUALLY] = function(irc)
    local nick = snowcone.irccase(irc[2])
    local hunt = irc_state.kline_hunt[nick]
    if hunt then
        if hunt.user and hunt.host and hunt.gecos then
            prepare_kline(irc[2], hunt.user, hunt.host, irc[3])
        else
            status('kline', 'Missing 314 response for ' .. irc[2])
        end
        irc_state.kline_hunt[nick] = nil
    end
end

return M
