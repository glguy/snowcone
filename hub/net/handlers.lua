-- Protocol handlers for inbound IRC messages.
--
-- Handlers update only the protocol model of the network: nick, channels,
-- members, modes, topics, away, isupport, capabilities, monitor. Buffers,
-- mentions, CTCP and notices to the user are features that subscribe to
-- `irc.message` and the events emitted here.
--
-- Each handler in M.by_command is called as h(rec, irc, msg) with the network record, its
-- model and the message. M.for_ircd gives a network's handlers, by its
-- ircd (net/ircd.lua): Solanum's are M.by_command.

local bus       <const> = require 'hub.runtime.bus'
local cap       <const> = require 'hub.net.cap'
local check     <const> = require 'hub.lib.check'
local clock     <const> = require 'hub.runtime.clock'
local intent    <const> = require 'hub.net.intent'
local irc_model <const> = require 'hub.net.irc'
local ircd      <const> = require 'hub.net.ircd'
local log       <const> = require 'hub.runtime.log'
local monitor   <const> = require 'hub.net.monitor'
local N         <const> = require 'hub.lib.numerics'
local NH        <const> = require 'hub.lib.numerics_hybrid'
local own_nick  <const> = require 'hub.net.nick'
local reclaim   <const> = require 'hub.net.reclaim'
local send      <const> = require 'hub.net.send'
local tablex    <const> = require 'pl.tablex'
local task      <const> = require 'hub.runtime.task'

local M = {}

-- [command] = handler
local H = {}
M.by_command = H

local function spawn_for(rec)
    return function(name, fn, ...)
        return task.spawn(name, {net = rec.id, owner = 'net'}, fn, ...)
    end
end

-- Ahead of anything the rate limit holds back, so a backlog can't time
-- us out
function H.PING(rec, _, msg)
    send.send_first(rec.id, 'PONG', msg[1] or '')
end

-- The answer to the lag PING (net/manager.lua)
function H.PONG(rec, _, msg)
    if rec.lag_token and msg[#msg] == rec.lag_token then
        rec.lag = clock.now() - rec.lag_sent
        rec.lag_token = nil
    end
end

function H.CAP(rec, irc, msg)
    cap.on_cap(irc, msg, spawn_for(rec))
end

-- "<client> <1-13 tokens> :are supported by this server"
H[N.RPL_ISUPPORT] = function(rec, irc, msg)
    for i = 2, #msg - 1 do
        local token = msg[i]
        local minus, key, equals, val = token:match '^(%-?)([^=]+)(=?)(.*)$'
        if key then
            if minus == '-' then
                val = nil
            elseif equals == '' then
                val = true
            else
                -- values escape bytes as \xHH
                val = val:gsub('\\x(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
            end
            irc_model.set_isupport(rec.id, irc, key, val)
        end
    end
end

-- From here our nick is the server's, and a refused NICK is the user's
-- own; before it, net/registration.lua answers refusals
H[N.RPL_WELCOME] = function(_, irc)
    irc.welcomed = true
end

-- "<client> <snomask> :Server notice mask"; a bare + when cleared
H[N.RPL_SNOMASK] = function(rec, irc, msg)
    if not msg[2] then return end
    irc.snomask = msg[2]:match '^%+?$' == nil and msg[2] or nil
    log.add_net(rec.id, 'irc', 'snomask %s', msg[2])
end

-- Operator status: from RPL_YOUREOPER or from user modes that include o
-- (opered before we connected, through a bouncer); irc.oper fires each
-- time we become one
local function now_oper(rec, irc)
    if not irc.oper then
        irc.oper = true
        bus.emit('irc.oper', {net = rec.id})
    end
end

-- Our user modes changed: o says whether we are an operator, and
-- without s there is no snomask (a server that strips it on deoper may
-- not say so with RPL_SNOMASK)
local function follow_umodes(rec, irc)
    if not irc.mode.s then
        irc.snomask = nil
    end
    if irc.mode.o then
        now_oper(rec, irc)
    elseif irc.oper then
        irc.oper = nil
        log.add_net(rec.id, 'irc', 'no longer oper')
    end
end

H[N.RPL_YOUREOPER] = function(rec, irc)
    log.add_net(rec.id, 'irc', "you're oper")
    now_oper(rec, irc)
end

-----------------------------------------------------------------------
-- Channel metadata

-- The topic it replaces goes with the message, which features see after
-- the model has forgotten it
function H.TOPIC(_, irc, msg)
    local channel = msg[1] and irc_model.known_channel(irc, msg[1])
    if channel then
        msg.topic_before = {topic = channel.topic, who = channel.topic_who, time = channel.topic_time}
        channel.topic = msg[2]
        channel.topic_who = msg.source
        channel.topic_time = irc_model.message_time(msg)
        irc_model.note_fetched(channel, 'topic')
    end
end

-- "<client> <channel> :<topic>"
H[N.RPL_TOPIC] = function(_, irc, msg)
    local channel = msg[2] and irc_model.known_channel(irc, msg[2])
    if channel then
        channel.topic = msg[3]
        irc_model.note_fetched(channel, 'topic')
    end
end

-- "<client> <channel> :No topic is set"
H[N.RPL_NOTOPIC] = function(_, irc, msg)
    local channel = msg[2] and irc_model.known_channel(irc, msg[2])
    if channel then
        channel.topic, channel.topic_who, channel.topic_time = '', nil, nil
        irc_model.note_fetched(channel, 'topic')
    end
end

-- "<client> <channel> <nick> <setat>"
H[N.RPL_TOPICWHOTIME] = function(_, irc, msg)
    local channel = msg[2] and irc_model.known_channel(irc, msg[2])
    if channel then
        channel.topic_who = msg[3]
        channel.topic_time = math.tointeger(tonumber(msg[4]))
    end
end

-- "<client> <channel> <creationtime>"
H[N.RPL_CREATIONTIME] = function(_, irc, msg)
    local channel = msg[2] and irc_model.known_channel(irc, msg[2])
    if channel then
        channel.creationtime = math.tointeger(tonumber(msg[3]))
    end
end

-----------------------------------------------------------------------
-- Monitor and nick recovery

-- :<server> 730 <nick> :target[!user@host][,target[!user@host]]*
H[N.RPL_MONONLINE] = function(rec, irc, msg)
    if not (irc.monitor and msg[2]) then return end
    monitor.on_reply(rec.id, irc, msg)
    local nicks = {}
    for nick in msg[2]:gmatch '([^!,]+)[^,]*,?' do
        table.insert(nicks, nick)
    end
    log.add_net(rec.id, 'monitor', 'monitor online: %s', table.concat(nicks, ', '))
end

-- :<server> 731 <nick> :target[,target2]*
H[N.RPL_MONOFFLINE] = function(rec, irc, msg)
    if not (irc.monitor and msg[2]) then return end
    monitor.on_reply(rec.id, irc, msg)
    local nicks = {}
    for nick in msg[2]:gmatch '([^!,]+)[^,]*,?' do
        table.insert(nicks, nick)
    end
    log.add_net(rec.id, 'monitor', 'monitor offline: %s', table.concat(nicks, ', '))
end

-- :<server> 734 <nick> <limit> <targets> :Monitor list is full.
H[N.ERR_MONLISTFULL] = function(rec, irc, msg)
    monitor.on_reply(rec.id, irc, msg)
    log.add_net(rec.id, 'monitor', 'monitor list full: %s', msg[3] or '')
end

-- A NICK for the wanted nick refused for now: it is taken (433), held
-- (437), refused while we are banned in a channel (435), or comes too
-- soon after others (438). The wanted nick is reclaimed, and the reclaim
-- task, started here, sees this refusal too. Before the welcome
-- net/registration.lua answers 433 and 437.
local function nick_refused(rec, irc, msg)
    if not irc.welcomed or irc.recover_nick then return end
    local wanted = irc_model.fold(irc, irc_model.cut_nick(irc, own_nick.wanted(rec)))
    -- Solanum's 438 names our nick, then the one refused
    for i = 2, #msg - 1 do
        if irc_model.fold(irc, msg[i]) == wanted then
            own_nick.want_back(rec, irc)
            return
        end
    end
end
H[N.ERR_NICKNAMEINUSE] = nick_refused
H[N.ERR_UNAVAILRESOURCE] = nick_refused
H[N.ERR_BANNICKCHANGE] = nick_refused
H[N.ERR_NICKTOOFAST] = nick_refused

-- A /nick the server won't take is no longer wanted, and the configured
-- nick is wanted back. Before the welcome net/registration.lua answers
-- this.
H[N.ERR_ERRONEUSNICKNAME] = function(rec, irc, msg)
    if not irc.welcomed then return end
    local wanted = intent.of(rec)
    if wanted.nick and msg[2]
       and irc_model.fold(irc, msg[2]) == irc_model.fold(irc, irc_model.cut_nick(irc, wanted.nick)) then
        wanted.nick = nil
        own_nick.want_back(rec, irc)
    end
end

-- The server's reason for closing the connection, which becomes the
-- reason it ended (net/manager.lua)
function H.ERROR(_, irc, msg)
    irc.error = msg[1]
end

-- "<client> :You are banned from this server- <reason>", before the
-- server closes the link: during registration, or when banned while
-- connected. The next attempt waits the longest delay (net/manager.lua).
H[N.ERR_YOUREBANNEDCREEP] = function(_, irc, msg)
    irc.banned = msg[#msg] or 'banned'
end

-----------------------------------------------------------------------
-- Users and channels

-- Names of the channels a user is in, sorted. QUIT and NICK messages carry
-- them as msg.channels, since the model forgets before features see them.
local function channels_of(irc, key)
    local names = {}
    for _, channel in pairs(irc.channels) do
        if channel.members[key] then
            table.insert(names, channel.name)
        end
    end
    table.sort(names)
    return names
end

function H.NICK(rec, irc, msg)
    local oldnick = msg.nick
    local newnick = msg[1]
    if not oldnick or not newnick then return end

    local oldkey = irc_model.fold(irc, oldnick)
    local newkey = irc_model.fold(irc, newnick)
    local self = irc_model.is_me(irc, oldnick)

    if self then
        irc.nick = newnick
        local asked = irc_model.take_nick_sent(irc, newnick)
        if irc.recover_nick and newkey == irc_model.fold(irc, irc.recover_nick) then
            reclaim.stop(rec, irc)
        elseif not asked and oldkey ~= newkey then
            if irc_model.behind_bouncer(irc) then
                -- perhaps another of the bouncer's clients: its nick to
                -- choose, and one we were reclaiming is no longer ours to
                reclaim.stop(rec, irc)
            else
                -- the server's doing: services, or a collision (RPL_SAVENICK)
                log.add_net(rec.id, 'irc', 'nick changed to %s by the server', newnick)
                own_nick.want_back(rec, irc)
            end
        end
    end

    msg.channels = channels_of(irc, oldkey)
    irc_model.rename_user(irc, oldnick, newnick)

    bus.emit('irc.nick', {net = rec.id, old = oldnick, new = newnick, self = self})
end

-- Our user@host changes; this message's own source shows the old one
function H.CHGHOST(_, irc, msg)
    if irc_model.is_me(irc, msg.nick) and msg[1] and msg[2] then
        irc.userhost = msg[1] .. '@' .. msg[2]
    end
end

-- "<client> <host> :is now your hidden host", perhaps user@host
H[N.RPL_HOSTHIDDEN] = function(_, irc, msg)
    local shown = msg[2]
    if not shown then return end
    if shown:find('@', 1, true) then
        irc.userhost = shown
    elseif irc.userhost then
        irc.userhost = irc.userhost:match '^[^@]*@' .. shown
    end
end

function H.JOIN(rec, irc, msg)
    local who = msg.nick
    local name = msg[1]
    if not who or not name then return end
    if irc_model.is_me(irc, who) then
        irc_model.join_channel(irc, name)
        intent.joined(rec, irc, name)
    end

    local channel = irc_model.get_channel(irc, name)
    if channel then
        irc_model.add_member(irc, channel, who, nil, true)
    end
end

-- "<client> <symbol> <channel> :[prefix]<nick>{ [prefix]<nick>}"
H[N.RPL_NAMREPLY] = function(_, irc, msg)
    local channel = msg[3] and irc_model.get_channel(irc, msg[3])
    if not channel or not msg[4] then return end

    -- Prefixes come off before the userhost (userhost-in-names) does;
    -- matching the nick first with '[^!@ ]+' would drop the @ of ops.
    for word in msg[4]:gmatch '[^ ]+' do
        local entry = word
        local modes = {}
        while entry ~= '' and irc.prefix_to_mode[entry:sub(1, 1)] do
            modes[irc.prefix_to_mode[entry:sub(1, 1)]] = true
            entry = entry:sub(2)
        end
        entry = entry:match '^[^!@]*'
        if entry ~= '' then
            irc_model.add_member(irc, channel, entry, modes)
        end
    end
end

-- "<client> <channel> :End of /NAMES list": a join brings a topic before
-- its names, or none when there is none
H[N.RPL_ENDOFNAMES] = function(_, irc, msg)
    local channel = msg[2] and irc_model.get_channel(irc, msg[2])
    if channel and channel.topic == nil then
        channel.topic = ''
    end
end

function H.PART(rec, irc, msg)
    local who = msg.nick
    local name = msg[1]
    if not who or not name then return end
    if irc_model.is_me(irc, who) then
        irc_model.drop_channel(irc, name)
        intent.left(rec, irc, name)
    else
        local channel = irc_model.get_channel(irc, name)
        if channel then
            irc_model.remove_member(irc, channel, who)
        end
    end
end

function H.KICK(rec, irc, msg)
    local name = msg[1]
    local target = msg[2]
    if not name or not target then return end
    if irc_model.is_me(irc, target) then
        irc_model.drop_channel(irc, name)
        intent.left(rec, irc, name)
    else
        local channel = irc_model.get_channel(irc, name)
        if channel then
            irc_model.remove_member(irc, channel, target)
        end
    end
end

function H.QUIT(_, irc, msg)
    local nick = msg.nick
    if not nick then return end
    local key = irc_model.fold(irc, nick)
    msg.channels = channels_of(irc, key)
    irc_model.remove_user(irc, nick)
end

-- No message, or an empty one, when back
function H.AWAY(_, irc, msg)
    if msg.nick then
        local text = msg[1]
        irc_model.set_away(irc, msg.nick, text ~= nil and text ~= '' and text or false)
    end
end

-- "<client> <nick> :<message>"
H[N.RPL_AWAY] = function(_, irc, msg)
    if msg[2] then
        local text = msg[3]
        irc_model.set_away(irc, msg[2], text ~= nil and text ~= '' and text or true)
    end
end

-- Replies to our own AWAY; the message is the one we sent
H[N.RPL_UNAWAY] = function(_, irc)
    if irc.nick then irc_model.set_away(irc, irc.nick, false) end
end
H[N.RPL_NOWAWAY] = function(rec, irc)
    if irc.nick then irc_model.set_away(irc, irc.nick, intent.of(rec).away or true) end
end

-----------------------------------------------------------------------
-- Modes

local function parse_umodes(modes, modestring)
    local polarity = true
    for m in modestring:gmatch '.' do
        if m == '+' then
            polarity = true
        elseif m == '-' then
            polarity = false
        else
            modes[m] = polarity or nil
        end
    end
end

function H.MODE(rec, irc, msg)
    local target = msg[1]
    local modestring = msg[2]
    local cursor = 3
    if not target or not modestring then return end

    if irc_model.is_me(irc, target) then
        parse_umodes(irc.mode, modestring)
        follow_umodes(rec, irc)
        return
    end

    if not irc_model.is_channel_name(irc, target) then return end
    local channel = irc_model.known_channel(irc, target)
    if not channel then return end -- mode information for a channel we don't track

    local polarity = true
    for flag in modestring:gmatch '.' do
        if flag == '+' then
            polarity = true
        elseif flag == '-' then
            polarity = false
        elseif irc.mode_to_prefix[flag] then
            local member = msg[cursor] and irc_model.get_member(irc, channel, msg[cursor])
            cursor = cursor + 1
            if member then
                member.modes[flag] = polarity or nil
            end
        elseif irc.modes_A:find(flag, 1, true) then
            local modes = channel.list_modes[flag]
            local mask = msg[cursor]
            cursor = cursor + 1
            if modes and mask then
                if polarity then
                    modes[mask] = {who = msg.source}
                else
                    modes[mask] = nil
                end
            end
        elseif irc.modes_B:find(flag, 1, true) then
            local modes = channel.modes
            if modes then
                modes[flag] = polarity and msg[cursor] or nil
            end
            -- the key to rejoin with
            if flag == 'k' and irc_model.get_channel(irc, target) then
                intent.channel_key(rec, irc, target, polarity and msg[cursor] or false)
            end
            cursor = cursor + 1
        elseif irc.modes_C:find(flag, 1, true) then
            local modes = channel.modes
            if polarity then
                if modes then modes[flag] = msg[cursor] end
                cursor = cursor + 1
            elseif modes then
                modes[flag] = nil
            end
        elseif irc.modes_D:find(flag, 1, true) then
            local modes = channel.modes
            if modes then
                modes[flag] = polarity or nil
            end
        end
    end
end

-- List modes arrive as entries, then an end numeric that stores them
local function list_entry(mask_index)
    return function(_, irc, msg)
        local mask = msg[mask_index]
        if not mask then return end
        local list = irc.partial_mode_list or {}
        irc.partial_mode_list = list
        list[mask] = {who = msg[mask_index + 1], ts = msg[mask_index + 2]}
    end
end

local function list_end(mode)
    return function(_, irc, msg)
        local channel = msg[2] and irc_model.known_channel(irc, msg[2])
        if channel then
            channel.list_modes[mode] = irc.partial_mode_list or {}
            irc_model.note_fetched(channel, mode)
        end
        irc.partial_mode_list = nil
    end
end

-- "<client> <channel> <mask> [<who> <set-ts>]"
H[N.RPL_BANLIST] = list_entry(3)
H[N.RPL_ENDOFBANLIST] = list_end 'b'
-- "<client> <channel> <mode> <mask> [<who> <set-ts>]"
H[N.RPL_QUIETLIST] = list_entry(4)
H[N.RPL_ENDOFQUIETLIST] = list_end 'q'
H[N.RPL_EXCEPTLIST] = list_entry(3)
H[N.RPL_ENDOFEXCEPTLIST] = list_end 'e'
H[N.RPL_INVITELIST] = list_entry(3)
H[N.RPL_ENDOFINVITELIST] = list_end 'I'

-- "<client> <channel> <modestring> <mode arguments>..."
H[N.RPL_CHANNELMODEIS] = function(rec, irc, msg)
    local channel = msg[2] and msg[3] and irc_model.known_channel(irc, msg[2])
    if not channel then return end
    irc_model.note_fetched(channel, 'modes')
    local cursor = 4
    local modes = {}
    channel.modes = modes
    for flag in msg[3]:gmatch '.' do
        if irc.modes_B:find(flag, 1, true) or irc.modes_C:find(flag, 1, true) then
            modes[flag] = msg[cursor]
            -- the key to rejoin with, shown to members
            if flag == 'k' and msg[cursor] and msg[cursor] ~= '*' and irc_model.get_channel(irc, msg[2]) then
                intent.channel_key(rec, irc, msg[2], msg[cursor])
            end
            cursor = cursor + 1
        elseif irc.modes_D:find(flag, 1, true) then
            modes[flag] = true
        end
    end
end

H[N.RPL_UMODEIS] = function(rec, irc, msg)
    if not msg[2] then return end
    local modes = {}
    parse_umodes(modes, msg[2])
    irc.mode = modes
    follow_umodes(rec, irc)
end

-----------------------------------------------------------------------
-- Accounts and SASL

-- <client> <mechanisms> :are available SASL mechanisms
H[N.RPL_SASLMECHS] = function(_, irc, msg)
    if not msg[2] then return end
    irc_model.set_sasl_mechs(irc, msg[2])
end

-- <client> <nick>!<ident>@<host> <account> :You are now logged in as <user>
H[N.RPL_LOGGEDIN] = function(_, irc, msg)
    irc.account = msg[3]
end

-- <client> <nick>!<ident>@<host> :You are now logged out
H[N.RPL_LOGGEDOUT] = function(_, irc)
    irc.account = nil
end

-----------------------------------------------------------------------
-- Bouncer (soju.im/bouncer-networks-notify)

function H.BOUNCER(_, irc, msg)
    -- BOUNCER NETWORK <netid> <tag-encoded attribute updates>
    -- Updates only make sense once the list arrived
    if 'NETWORK' ~= msg[1] or not irc.bouncer_networks then return end
    local netid, attrs = msg[2], msg[3]

    -- * indicates the network was deleted
    if attrs == '*' then
        irc.bouncer_networks[netid] = nil
        return
    end

    local updates = check(snowcone.parse_irc_tags(attrs or ''),
        'bad BOUNCER NETWORK attributes: ' .. tostring(attrs))
    local network = irc.bouncer_networks[netid]
    if nil == network then
        network = {}
        irc.bouncer_networks[netid] = network
    end
    for k, v in pairs(updates) do
        -- no value indicates the attribute was deleted; tag syntax makes
        -- that the same as an empty one
        if v == '' then
            network[k] = nil
        else
            network[k] = v
        end
    end
end

-- Commands a user sends to a channel take the sender's prefix modes there
-- as they were before the command took effect (msg.member_modes): a PART
-- or MODE changes them before features see the message.
for command in pairs(irc_model.channel_commands) do
    local h = H[command]
    H[command] = function(rec, irc, msg)
        local channel = msg.nick and irc_model.sent_to_channel(irc, msg)
        if channel then
            msg.member_modes = irc_model.member_modes(irc, channel, msg.nick)
        end
        if h then return h(rec, irc, msg) end
    end
end

-- OFTC hybrid's quiet list is 344 and 345, without the mode; its 728 is
-- capture, and 8 and 729 are unused
local hybrid = tablex.copy(H)
hybrid[N.RPL_SNOMASK] = nil
hybrid[N.RPL_QUIETLIST] = nil
hybrid[N.RPL_ENDOFQUIETLIST] = nil
-- "<client> <channel> <mask> <who> <set-ts>"
hybrid[NH.RPL_QUIETLIST] = list_entry(3)
hybrid[NH.RPL_ENDOFQUIETLIST] = list_end 'q'

local by_ircd <const> = {
    [ircd.SOLANUM] = H,
    [ircd.HYBRID] = hybrid,
}

--- A network's handlers, by command.
---@param net string
---@return table<string|integer, function>
function M.for_ircd(net)
    return by_ircd[ircd.of(net)]
end

return M
