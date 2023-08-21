-- Logic for IRC messages
local tablex      = require 'pl.tablex'

local N           = require_ 'utils.numerics'
local challenge   = require_ 'utils.challenge'
local sasl        = require_ 'sasl'
local send        = require_ 'utils.send'
local split_nuh   = require_ 'utils.split_nick_user_host'
local Buffer      = require  'components.Buffer'
local Channel     = require  'components.Channel'
local Member      = require  'components.Member'

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

local function do_notify(target, nick, text)
    if not terminal_focus
    and not notification_muted[target]
    and configuration.notification_module then
        notification_muted[target] = true -- use up the notification until next focus
        require(configuration.notification_module)(target, nick, text)
    end
end

local function route_to_buffer(target, text, irc)
    local buffer_target
    local mention
    local nick = split_nuh(irc.source)

    if irc_state:is_channel_name(target) then
        buffer_target = target

        -- channel messages generate mention on pattern match
        local mention_patterns = configuration.mention_patterns
        if mention_patterns then
            for _, pattern in ipairs(mention_patterns) do
                if text:find(pattern) then
                    mention = true
                    break;
                end
            end
        end
    else
        buffer_target = nick

        -- Targetted PMs notify
        if target == irc_state.nick then
            mention = true
        end
    end

    if mention then
        do_notify(buffer_target, nick, text)
    end

    -- will be nil in the case of a message from a server
    local buffer
    if buffer_target then
        local buffer_key = snowcone.irccase(buffer_target)
        buffer = buffers[buffer_key]
        if not buffer then
            buffer = Buffer(buffer_target)
            buffers[buffer_key] = buffer
        end
        buffer.name = buffer_target
        buffer.messages:insert(true, irc)
        buffer.mention = mention
    end
end

local ctcp_handlers = require_ 'handlers.ctcp'
function M.PRIVMSG(irc)
    local target, message = irc[1], irc[2]
    local ctcp, ctcp_args = message:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'

    -- reply only to targetted CTCP requests from staff
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

    route_to_buffer(target, message, irc)
end

function M.NOTICE(irc)
    local target, message = irc[1], irc[2]
    route_to_buffer(target, message, irc)
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
    local newnick = irc[1]

    -- My nickname is changing
    if nick and nick == irc_state.nick then
        irc_state.nick = newnick
        if irc_state.target_nick == irc_state.nick then
            irc_state.target_nick = nil
        end
    end

    local oldkey = snowcone.irccase(nick)
    local newkey = snowcone.irccase(newnick)
    local rename = oldkey ~= newkey

    local user = irc_state:get_user(nick)
    -- get_user *always* returns a table
    user.nick = newnick
    if rename then
        irc_state.users[oldkey] = nil
        irc_state.users[newkey] = user
    end

    -- Update all the channel lists
    for _, channel in pairs(irc_state.channels) do
        local member = channel.members[oldkey]
        if member then
            if rename then
                channel.members[oldkey] = nil
                channel.members[newkey] = member
            end
        end
    end

    -- Update buffer names
    local buffer = buffers[oldkey]
    if buffer then
        buffer.name = newnick
        if rename then
            buffers[oldkey] = nil
            buffers[newkey] = buffer
        end
    end

    if oldkey ~= newkey and irc_state:has_monitor() then
        local monitor = irc_state.monitor[oldkey]
        if monitor then
            if rename then
                monitor[oldkey] = nil
                monitor[newkey] = monitor
                send('MONITOR', '+', newnick)
                send('MONITOR', '-', nick)
            end
        end
    end

    if talk_target and talk_target == oldkey then
        talk_target = newkey
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

local batch_handlers = require_ 'handlers.batch'
function M.BATCH(irc)
    local polarity = irc[1]:sub(1,1)
    local name = irc[1]:sub(2)

    -- start of batch
    if '+' == polarity then
        irc_state.batches[name] = {
            identifier = irc[2],
            params = tablex.sub(irc, 3),
            messages = {},
            n = 0
        }

    -- end of batch
    elseif '-' == polarity then
        local batch = irc_state.batches[name]
        irc_state.batches[name] = nil
        if batch then
            local h = batch_handlers[batch.identifier]
            if h then
                h(batch.params, batch.messages)
            end
        end
    end
end

-- Support for draft/bouncer-networks-notify
function M.BOUNCER(irc)
    -- BOUNCER NETWORK <netid> <tag-encoded attribute updates>
    if 'NETWORK' == irc[1] then
        -- These messages are updates, so they only make sense if we've seen the list already
        if irc_state.bouncer_networks then
            local netid, attrs = irc[2], irc[3]

            -- * indicates the network was deleted
            if attrs == '*' then
                irc.bouncer_networks[netid] = nil
            else
                local network = irc_state.bouncer_networks[netid]
                if nil == network then
                    network = {}
                    irc_state.bouncer_networks[netid] = network
                end
                for k, v in pairs(snowcone.parse_irc_tags(attrs)) do
                    -- No value indicates the attribute was deleted
                    if true == v then
                        network[k] = nil
                    else
                        network[k] = v
                    end
                end
            end
        end
    end
end

function M.MODE(irc)
    local target = irc[1]

    -- Update self umodes
    if target == irc_state.nick then
        local polarity = true
        for m in irc[2]:gmatch '.' do
            if m == '+' then
                polarity = true
            elseif m == '-' then
                polarity = false
            elseif m == 'o' then
                irc_state.oper = polarity
            end
        end
    end
end

function M.JOIN(irc)
    local who = split_nuh(irc.source)
    local channel = irc[1]
    if who == irc_state.nick then
        irc_state.channels[snowcone.irccase(channel)] = Channel(channel)
    end

    local user = irc_state:get_user(who)
    irc_state:get_channel(channel).members[snowcone.irccase(who)] = Member(user)
end

-- "<client> <symbol> <channel> :[prefix]<nick>{ [prefix]<nick>}"
M[N.RPL_NAMREPLY] = function(irc)
    local name, nicks = irc[3], irc[4]
    local channel = irc_state:get_channel(name)

    for entry in nicks:gmatch '[^ ]+' do
        local modes = {}
        while irc_state.prefix_to_mode[entry:sub(1,1)] do
            modes[irc_state.prefix_to_mode[entry:sub(1,1)]] = true
            entry = entry:sub(2)
        end
        local user = irc_state:get_user(entry)
        local member = Member(user)
        member.modes = modes
        channel.members[snowcone.irccase(entry)] = member
    end
end

function M.PART(irc)
    local who = split_nuh(irc.source)
    local channel = irc[1]
    if who == irc_state.nick then
        irc_state.channels[snowcone.irccase(channel)] = nil
    else
        irc_state:get_channel(channel).members[snowcone.irccase(who)] = nil
    end
end

function M.QUIT(irc)
    local nick = split_nuh(irc.source)
    local key = snowcone.irccase(nick)

    for _, channel in pairs(irc_state.channels) do
        channel.members[snowcone.irccase(nick)] = nil
    end

    irc_state.users[key] = nil
end

function M.KICK(irc)
    local channel = irc[1]
    local target = irc[2]
    if target == irc_state.nick then
        irc_state.channels[snowcone.irccase(channel)] = nil
    else
        irc_state:get_channel(channel).members[snowcone.irccase(target)] = nil
    end
end

function M.AWAY(irc)
    local nick = split_nuh(irc.source)
    local user = irc_state:get_user(nick)
    user.away = irc[1] -- will be nil when BACK
end

-- "<client> <nick> :<message>"
M[N.RPL_AWAY] = function(irc)
    local nick = irc[2]
    local user = irc_state:get_user(nick)
    user.away = irc[3]
end

M[N.RPL_WELCOME] = function(irc)
    irc_state.nick = irc[1]
end

M[N.RPL_ISUPPORT] = function(irc)
    local isupport = irc_state.isupport
    if isupport == nil then
        isupport = {}
        irc_state.isupport = isupport
    end

    for i = 2, #irc - 1 do
        local token = irc[i]
        -- soju.im/bouncer-networks happens to add _ to the allowed characters
        local minus, key, equals, val = string.match(token, '^(%-?)([%u%d_]+)(=?)(.*)$')
        if minus == '-' then
            isupport[key] = nil
        elseif equals == '' then
            isupport[key] = true
        else
            isupport[key] = val
        end
    end
end

local function end_of_registration()
    irc_state.phase = 'connected'
    status('irc', 'connected')

    irc_state:commit_isupport()

    if configuration.oper_username and configuration.challenge_key then
        challenge.start()
    elseif configuration.oper_username and configuration.oper_password then
        send('OPER', configuration.oper_username,
            {content=configuration.oper_password, secret=true})
    else
        -- determine if we're already oper
        send('MODE', irc_state.nick)
    end

    if irc_state:has_chathistory() then
        local supported_amount = irc_state.max_chat_history
        for target, buffer in pairs(buffers) do
            local amount = buffer.messages.max

            if supported_amount and supported_amount < amount then
                amount = supported_amount
            end

            local ts
            local lastirc = buffer.messages:lookup(true)
            if lastirc and lastirc.tags.time then
                ts = 'timestamp=' .. lastirc.tags.time
            else
                ts = '*'
            end

            send('CHATHISTORY', 'LATEST', target, ts, amount)
        end
    end

    -- reinstall monitors for the active private message buffers
    if irc_state:has_monitor() then
        local n, nicks = 0, {}
        for target, _ in pairs(buffers) do
            if not irc_state:is_channel_name(target) then
                table.insert(nicks, target)
                n = 1 + #target
                if n > 400 then
                    send('MONITOR', '+', table.concat(nicks, ','))
                    n, nicks = 0, {}
                end
            end
        end
        if n > 0 then
            send('MONITOR', '+', table.concat(nicks, ','))
        end
    end
end

M[N.RPL_ENDOFMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
    end
end

M[N.ERR_NOMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
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
    status('irc', "you're oper")
end

-----------------------------------------------------------------------

M[N.RPL_LIST] = function(irc)
    if irc_state.channel_list_complete then
        irc_state.channel_list = {}
        irc_state.channel_list_complete = nil
    elseif not irc_state.channel_list then
        irc_state.channel_list = {}
    end

    irc_state.channel_list[irc[2]] = {
        users = tonumber(irc[3]),
        topic = irc[4],
    }
end

M[N.RPL_LISTEND] = function()
    irc_state.channel_list_complete = true
end

-----------------------------------------------------------------------
-- Channel metadata

function M.TOPIC(irc)
    irc_state:get_channel(irc[1]).topic = irc[2]
end

-- "<client> <channel> :<topic>"
M[N.RPL_TOPIC] = function(irc)
    irc_state:get_channel(irc[2]).topic = irc[3]
end

M[N.RPL_CREATIONTIME] = function(irc)
    irc_state:get_channel(irc[2]).creationtime = tonumber(irc[3])
end

-----------------------------------------------------------------------
-- Monitor support

-- :<server> 730 <nick> :target[!user@host][,target[!user@host]]*
M[N.RPL_MONONLINE] = function(irc)
    local list = irc[2]
    local nicks = {}
    for nick in list:gmatch '([^!,]+)[^,]*,?' do
        irc_state:add_monitor(nick, true)
        table.insert(nicks, nick)
    end
    status('monitor', 'monitor online: ' .. table.concat(nicks, ', '))
end

-- :<server> 731 <nick> :target[,target2]*
M[N.RPL_MONOFFLINE] = function(irc)
    local list = irc[2]
    local nicks = {}
    for nick in list:gmatch '([^!,]+)[^,]*,?' do
        irc_state:add_monitor(nick, false)
        table.insert(nicks, nick)
    end
    status('monitor', 'monitor offline: ' .. table.concat(nicks, ', '))
end

M[N.ERR_MONLISTFULL] = function()
    status('monitor', 'monitor list full')
end

-----------------------------------------------------------------------

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
    if irc_state.phase == 'registration' then
        local nick = string.format('%.10s-%05d', configuration.nick, math.random(0,99999))
        irc_state.target_nick = configuration.nick
        send('NICK', nick)
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

return M
