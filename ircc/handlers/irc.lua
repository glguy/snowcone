-- Logic for IRC messages
local tablex      = require 'pl.tablex'
local Set         = require 'pl.Set'

local N           = require_ 'utils.numerics'
local send        = require_ 'utils.send'
local split_nuh   = require_ 'utils.split_nick_user_host'
local Buffer      = require  'components.Buffer'
local Channel     = require  'components.Channel'
local Member      = require  'components.Member'
local Task        = require  'components.Task'
local split_statusmsg = require 'utils.split_statusmsg'

local function parse_source(source)
    return string.match(source, '^(.-)!(.-)@(.*)$')
end

--- Add an IRC message to a buffer and update other metadata
---@param buffer_name string
---@param irc table
---@param mention boolean
local function add_to_buffer(buffer_name, irc, mention)
    local buffer_key = snowcone.irccase(buffer_name)
    local buffer = buffers[buffer_key]
    if buffer then
        buffer.name = buffer_name
    else
        buffer = Buffer(buffer_name)
        buffers[buffer_key] = buffer
    end
    buffer.messages:insert(true, irc)
    if mention then
        buffer.mention = true
    end
end

local M = {}

function M.ERROR()
    irc_state.phase = 'closed'
end

function M.PING(irc)
    send('PONG', irc[1])
end

local cap_cmds = require_ 'handlers.cap'
function M.CAP(irc)
    -- irc[1] is a nickname or *
    local h = cap_cmds[irc[2]]
    if h then
        h(table.unpack(irc, 3))
    end
end

-- "<client> <1-13 tokens> :are supported by this server"
M[N.RPL_ISUPPORT] = function(irc)
    for i = 2, #irc - 1 do
        local token = irc[i]
        local minus, key, equals, val = token:match '^(%-?)([^=]+)(=?)(.*)$'
        if minus == '-' then
            val = nil
        elseif equals == '' then
            val = true
        end
        irc_state:set_isupport(key, val)
    end
end

M[N.RPL_SNOMASK] = function(irc)
    status('irc', 'snomask %s', irc[2])
end

-----------------------------------------------------------------------
-- Channel metadata

function M.TOPIC(irc)
    local target = irc[1]
    irc_state:get_channel(target).topic = irc[2]
    add_to_buffer(target, irc, false)
end

-- "<client> <channel> :<topic>"
M[N.RPL_TOPIC] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.topic = irc[3]
    end
end

-- "<client> <channel> <creationtime>"
M[N.RPL_CREATIONTIME] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.creationtime = tonumber(irc[3])
    end
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

        if snowcone.irccase(nick) == irc_state.recover_nick then
            send('NICK', configuration.nick)
        end
    end
    status('monitor', 'monitor offline: ' .. table.concat(nicks, ', '))
end

M[N.ERR_MONLISTFULL] = function()
    status('monitor', 'monitor list full')
end

-----------------------------------------------------------------------

local function new_nickname()
    if irc_state.phase == 'registration' then
        local nick = string.format('%.10s-%05d', configuration.nick, math.random(0,99999))
        send('NICK', nick)
        irc_state.recover_nick = snowcone.irccase(configuration.nick)
        irc_state.nick = nick -- optimistic
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

local function do_notify(target, nick, text)
    local key = snowcone.irccase(target)
    if not terminal_focus
    and configuration.notification_module then
        local previous = notification_muted[key]
        notification_muted[key] = require(configuration.notification_module).notify(previous, target, nick, text)
    end
end

local function route_chat_to_buffer(target, text, irc)
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

    elseif nick and nick == irc_state.nick then
        -- this is a message I sent that a bouncer is relaying to me
        -- or that I sent to myself
        buffer_target = target

    elseif target == irc_state.nick then
        buffer_target = nick
        mention = true
    end

    if mention and buffer_target and nick then
        do_notify(buffer_target, nick, text)
    end

    -- will be nil in the case of a message from a server
    if buffer_target then
        add_to_buffer(buffer_target, irc, mention)
    end
end

local ctcp_handlers = require_ 'handlers.ctcp'
function M.PRIVMSG(irc)
    local prefix, target = split_statusmsg(irc[1])
    local message = irc[2]
    local ctcp, ctcp_args = message:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'
    irc.statusmsg = prefix

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

    route_chat_to_buffer(target, message, irc)
end

function M.NOTICE(irc)
    local prefix, target = split_statusmsg(irc[1])
    local message = irc[2]
    irc.statusmsg = prefix
    route_chat_to_buffer(target, message, irc)
end

function M.WALLOPS(irc)
    local nick = split_nuh(irc.source)
    status('wallops', '%s: %s', nick, irc[1])
end

function M.OPERWALL(irc)
    local nick = split_nuh(irc.source)
    status('operwall', '%s: %s', nick, irc[1])
end

function M.NICK(irc)
    local oldnick = parse_source(irc.source)
    local newnick = irc[1]

    local oldkey = snowcone.irccase(oldnick)
    local newkey = snowcone.irccase(newnick)
    local rename = oldkey ~= newkey

    -- My nickname is changing
    if oldnick and oldnick == irc_state.nick then
        irc_state.nick = newnick

        if newkey == irc_state.recover_nick then
            irc_state.recover_nick = nil
            send('MONITOR', '-', newnick)
            irc_state:del_monitor(newnick)
        end
    end

    -- Nicknames are tracked in:
    -- * users table
    -- * channel members
    -- * buffers
    -- * monitor tracking
    -- * talk target


    local user = irc_state:get_user(oldnick)
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
            add_to_buffer(channel.name, irc, false)
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
        add_to_buffer(newnick, irc, false)
    end

    if talk_target and talk_target == oldkey then
        -- don't call set_talk_target; it's a rename
        talk_target = newkey
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
                irc_state.bouncer_networks[netid] = nil
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

-----------------------------------------------------------------------
-- MODE processing

function M.MODE(irc)
    local target = irc[1]
    local modestring = irc[2]
    local cursor = 3

    -- Update self umodes
    if target == irc_state.nick then
        local polarity = true
        for m in modestring:gmatch '.' do
            if m == '+' then
                polarity = true
            elseif m == '-' then
                polarity = false
            else
                irc_state.mode[m] = polarity or nil
            end
        end

    -- update channel modes
    elseif irc_state:is_channel_name(target) then
        local channel = irc_state:get_channel(target)
        if channel then -- you can get mode information for channels you aren't in
            local polarity = true
            for flag in modestring:gmatch '.' do
                if flag == '+' then
                    polarity = true
                elseif flag == '-' then
                    polarity = false
                elseif irc_state.mode_to_prefix[flag] then
                    local modes = channel:get_member(irc[cursor]).modes
                    cursor = cursor + 1
                    if polarity then
                        modes[flag] = true
                    else
                        modes[flag] = nil
                    end
                elseif irc_state.modes_A:find(flag, 1, true) then
                    local modes = channel.list_modes[flag]
                    local mask = irc[cursor]
                    cursor = cursor + 1
                    if modes then
                        if polarity then
                            modes[mask] = {
                                who = irc.source
                            }
                        else
                            modes[mask] = nil
                        end
                    end
                elseif irc_state.modes_B:find(flag, 1, true) then
                    local modes = channel.modes
                    if modes then
                        if polarity then
                            modes[flag] = irc[cursor]
                        else
                            modes[flag] = nil
                        end
                    end
                    cursor = cursor + 1
                elseif irc_state.modes_C:find(flag, 1, true) then
                    local modes = channel.modes
                    if modes then
                        if polarity then
                            modes[flag] = irc[cursor]
                            cursor = cursor + 1
                        else
                            modes[flag] = nil
                        end
                    elseif polarity then
                        cursor = cursor + 1
                    end
                elseif irc_state.modes_D:find(flag, 1, true) then
                    local modes = channel.modes
                    if modes then
                        if polarity then
                            modes[flag] = true
                        else
                            modes[flag] = nil
                        end
                    end
                end
            end
        end
        add_to_buffer(target, irc, false)
    end
end

-- "<client> <channel> <mask> [<who> <set-ts>]"
M[N.RPL_BANLIST] = function(irc)
    local mode_list = irc_state:get_partial_mode_list();
    mode_list[irc[3]] = {
        who = irc[4],
        ts = irc[5],
    }
end

--  "<client> <channel> :End of Channel Ban List"
M[N.RPL_ENDOFBANLIST] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.list_modes.b = irc_state:get_partial_mode_list()
        irc_state:clear_partial_mode_list()
    end
end

-- "<client> <channel> <mode> <mask> [<who> <set-ts>]"
M[N.RPL_QUIETLIST] = function(irc)
    local mode_list = irc_state:get_partial_mode_list();
    mode_list[irc[4]] = {
        who = irc[5],
        ts = irc[6],
    }
end

-- "<client> <channel> <mode> :End of channel quiet list"
M[N.RPL_ENDOFQUIETLIST] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.list_modes.q = irc_state:get_partial_mode_list()
        irc_state:clear_partial_mode_list()
    end
end

-- "<client> <channel> <mask> [<who> <set-ts>]"
M[N.RPL_EXCEPTLIST] = function(irc)
    local mode_list = irc_state:get_partial_mode_list();
    mode_list[irc[3]] = {
        who = irc[4],
        ts = irc[5],
    }
end

-- "<client> <channel> :End of channel exception list"
M[N.RPL_ENDOFEXCEPTLIST] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.list_modes.e = irc_state:get_partial_mode_list()
        irc_state:clear_partial_mode_list()
    end
end

-- "<client> <channel> <mask> [<who> <set-ts>]"
M[N.RPL_INVITELIST] = function(irc)
    local mode_list = irc_state:get_partial_mode_list();
    mode_list[irc[3]] = {
        who = irc[4],
        ts = irc[5],
    }
end

--   "<client> <channel> :End of Channel Invite Exception List"
M[N.RPL_ENDOFINVITELIST] = function(irc)
    local channel = irc_state:get_channel(irc[2])
    if channel then
        channel.list_modes.I = irc_state:get_partial_mode_list()
        irc_state:clear_partial_mode_list()
    end
end

-- "<client> <channel> <modestring> <mode arguments>..."
M[N.RPL_CHANNELMODEIS] = function(irc)
    local name = irc[2]
    local modestring = irc[3]
    local cursor = 4

    local channel = irc_state:get_channel(name)
    if channel then
        local modes = {}
        channel.modes = modes
        for flag in modestring:gmatch '.' do
            if irc_state.modes_B:find(flag, 1, true) then
                modes[flag] = irc[cursor]
                cursor = cursor + 1
            elseif irc_state.modes_C:find(flag, 1, true) then
                modes[flag] = irc[cursor]
                cursor = cursor + 1
            elseif irc_state.modes_D:find(flag, 1, true) then
                modes[flag] = true
            end
        end
    end
end

M[N.RPL_UMODEIS] = function(irc)
    local polarity = true
    local modes = {}
    for m in irc[2]:gmatch '.' do
        if m == '+' then
            polarity = true
        elseif m == '-' then
            polarity = false
        else
            modes[m] = polarity or nil
        end
    end
    irc_state.mode = modes
end


-----------------------------------------------------------------------

function M.JOIN(irc)
    local who = split_nuh(irc.source)
    local channel = irc[1]
    if who == irc_state.nick then
        irc_state.channels[snowcone.irccase(channel)] = Channel(channel)
    end

    local user = irc_state:get_user(who)
    irc_state:get_channel(channel).members[snowcone.irccase(who)] = Member(user)
    add_to_buffer(channel, irc, false)
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
    add_to_buffer(channel, irc, false)
end

function M.QUIT(irc)
    local nick = split_nuh(irc.source)
    local key = snowcone.irccase(nick)

    for _, channel in pairs(irc_state.channels) do
        if channel.members[key] then
            add_to_buffer(channel.name, irc, false)
        end
        channel.members[key] = nil
    end

    if buffers[key] then
        add_to_buffer(nick, irc, false)
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
    add_to_buffer(channel, irc, false)
end

function M.AWAY(irc)
    local nick = split_nuh(irc.source)
    local user = irc_state:get_user(nick)
    user.away = irc[1] -- will be nil when BACK
end

function M.ACCOUNT(irc)
    -- the client doesn't track user account names

    local nick = split_nuh(irc.source)
    local key = snowcone.irccase(nick)
    for _, channel in pairs(irc_state.channels) do
        local member = channel.members[key]
        if member then
            add_to_buffer(channel.name, irc, false)
        end
    end
    if buffers[key] then
        add_to_buffer(nick, irc, false)
    end
end

function M.CHGHOST(irc)
    -- the client doesn't track user hostnames

    local nick = split_nuh(irc.source)
    local key = snowcone.irccase(nick)
    for _, channel in pairs(irc_state.channels) do
        local member = channel.members[key]
        if member then
            add_to_buffer(channel.name, irc, false)
        end
    end
    if buffers[key] then
        add_to_buffer(nick, irc, false)
    end
end

-- "<client> <nick> :<message>"
M[N.RPL_AWAY] = function(irc)
    local nick = irc[2]
    local user = irc_state:get_user(nick)
    user.away = irc[3]
end

-- <client> <mechanisms> :are available SASL mechanisms
M[N.RPL_SASLMECHS] = function(irc)
    irc_state:set_sasl_mechs(irc[2])
end

-- <client> <nick>!<ident>@<host> <account> :You are now logged in as <user>
M[N.RPL_LOGGEDIN] = function(irc)
    irc_state:set_account(irc[3])
end

-- <client> <nick>!<ident>@<host> :You are now logged out
M[N.RPL_LOGGEDOUT] = function()
    irc_state:set_account(nil)
end

-- "<client> :You have already authenticated using SASL"
M[N.ERR_SASLALREADY] = function()
    status('sasl', 'SASL already complete')
end

-- "<client> :You must use a nick assigned to you
M[N.ERR_NICKLOCKED] = function()
    status('sasl', 'Must use assigned nickname')
end

return M
