-- Protocol handlers for inbound IRC messages (from ircc/handlers/irc.lua).
--
-- Handlers update only the protocol model of the network: nick, channels,
-- members, modes, topics, away, isupport, capabilities, monitor. Buffers,
-- mentions, CTCP and notices to the user are features that subscribe to
-- `irc.message` and the events emitted here.
--
-- Each handler in M.commands is called as h(rec, irc, msg) with the network record, its
-- model and the message.

local bus       <const> = require 'hub.runtime.bus'
local cap       <const> = require 'hub.net.cap'
local clock     <const> = require 'hub.runtime.clock'
local irc_model <const> = require 'hub.net.irc'
local log       <const> = require 'hub.runtime.log'
local N         <const> = require 'hub.lib.numerics'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'

local M = {}

-- [command] = handler
local H = {}
M.commands = H

local function spawn_for(rec)
    return function(name, fn, ...)
        return task.spawn(name, {net = rec.id, owner = 'net'}, fn, ...)
    end
end

function H.PING(rec, _, msg)
    send.send(rec.id, 'PONG', msg[1])
end

-- The answer to the lag PING (net/manager.lua)
function H.PONG(rec, _, msg)
    if rec.lag_token and msg[#msg] == rec.lag_token then
        rec.lag = clock.now() - rec.lag_sent
        rec.lag_token = nil
    end
end

function H.CAP(rec, irc, msg)
    cap.on_cap(rec.id, irc, msg, spawn_for(rec))
end

-- "<client> <1-13 tokens> :are supported by this server"
H[N.RPL_ISUPPORT] = function(rec, irc, msg)
    for i = 2, #msg - 1 do
        local token = msg[i]
        local minus, key, equals, val = token:match '^(%-?)([^=]+)(=?)(.*)$'
        if minus == '-' then
            val = nil
        elseif equals == '' then
            val = true
        end
        irc_model.set_isupport(rec.id, irc, key, val)
    end
end

H[N.RPL_SNOMASK] = function(rec, irc, msg)
    irc.snomask = msg[2]
    log.add_net(rec.id, 'irc', 'snomask %s', msg[2])
end

-- Operator status, once per connection: from RPL_YOUREOPER or from user
-- modes that include o (opered before we connected, through a bouncer)
local function now_oper(rec, irc)
    if not irc.oper then
        irc.oper = true
        bus.emit('irc.oper', {net = rec.id})
    end
end

H[N.RPL_YOUREOPER] = function(rec, irc)
    log.add_net(rec.id, 'irc', "you're oper")
    now_oper(rec, irc)
end

-----------------------------------------------------------------------
-- Channel metadata

function H.TOPIC(_, irc, msg)
    local channel = irc_model.get_channel(irc, msg[1])
    if channel then
        channel.topic = msg[2]
    end
end

-- "<client> <channel> :<topic>"
H[N.RPL_TOPIC] = function(_, irc, msg)
    local channel = irc_model.get_channel(irc, msg[2])
    if channel then
        channel.topic = msg[3]
    end
end

-- "<client> <channel> <creationtime>"
H[N.RPL_CREATIONTIME] = function(_, irc, msg)
    local channel = irc_model.get_channel(irc, msg[2])
    if channel then
        channel.creationtime = tonumber(msg[3])
    end
end

-----------------------------------------------------------------------
-- Monitor and nick recovery

local function want_nick(rec, irc, nick)
    return irc.recover_nick and rec.cfg.reclaim_nick
       and irc_model.fold(irc, nick) == irc.recover_nick
end

--- Try to take the configured nick back. Also a route, so that features
--- that see the nick become free (server notices) can trigger it.
function M.reclaim_nick(net)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if irc and irc.recover_nick and rec.cfg.reclaim_nick and rec.phase == 'connected' then
        send.send(net, 'NICK', rec.cfg.identity.nick)
    end
end

-- :<server> 730 <nick> :target[!user@host][,target[!user@host]]*
H[N.RPL_MONONLINE] = function(rec, irc, msg)
    if not irc.monitor then return end
    local nicks = {}
    for nick in msg[2]:gmatch '([^!,]+)[^,]*,?' do
        irc_model.add_monitor(irc, nick, true)
        table.insert(nicks, nick)
    end
    log.add_net(rec.id, 'monitor', 'monitor online: %s', table.concat(nicks, ', '))
end

-- :<server> 731 <nick> :target[,target2]*
H[N.RPL_MONOFFLINE] = function(rec, irc, msg)
    if not irc.monitor then return end
    local nicks = {}
    for nick in msg[2]:gmatch '([^!,]+)[^,]*,?' do
        irc_model.add_monitor(irc, nick, false)
        table.insert(nicks, nick)
        if want_nick(rec, irc, nick) then
            M.reclaim_nick(rec.id)
        end
    end
    log.add_net(rec.id, 'monitor', 'monitor offline: %s', table.concat(nicks, ', '))
end

H[N.ERR_MONLISTFULL] = function(rec)
    log.add_net(rec.id, 'monitor', 'monitor list full')
end

-- During registration a rejected nick gets a random replacement, and the
-- configured one is reclaimed later
local function new_nickname(rec, irc)
    if rec.phase == 'registering' then
        local wanted = rec.cfg.identity.nick
        local nick = string.format('%.10s-%05d', wanted, math.random(0, 99999))
        send.send(rec.id, 'NICK', nick)
        irc.recover_nick = irc_model.fold(irc, wanted)
        irc.nick = nick -- optimistic
    end
end

H[N.ERR_ERRONEUSNICKNAME] = new_nickname
H[N.ERR_NICKNAMEINUSE] = new_nickname
H[N.ERR_UNAVAILRESOURCE] = new_nickname

-----------------------------------------------------------------------
-- Users and channels

function H.NICK(rec, irc, msg)
    local oldnick = msg.nick
    local newnick = msg[1]
    if not oldnick then return end

    local oldkey = irc_model.fold(irc, oldnick)
    local newkey = irc_model.fold(irc, newnick)
    local rename = oldkey ~= newkey
    local self = oldnick == irc.nick

    if self then
        irc.nick = newnick
        if newkey == irc.recover_nick then
            irc.recover_nick = nil
            if irc.monitor then
                send.send(rec.id, 'MONITOR', '-', newnick)
                irc_model.del_monitor(irc, newnick)
            end
        end
    end

    local user = irc_model.get_user(irc, oldnick)
    user.nick = newnick
    if rename then
        irc.users[oldkey] = nil
        irc.users[newkey] = user
    end

    for _, channel in pairs(irc.channels) do
        local member = channel.members[oldkey]
        if member and rename then
            channel.members[oldkey] = nil
            channel.members[newkey] = member
        end
    end

    bus.emit('irc.nick', {net = rec.id, old = oldnick, new = newnick, self = self})
end

function H.JOIN(_, irc, msg)
    local who = msg.nick
    local name = msg[1]
    if who == irc.nick then
        irc.channels[irc_model.fold(irc, name)] = irc_model.new_channel(name)
    end

    local channel = irc_model.get_channel(irc, name)
    if channel then
        channel.members[irc_model.fold(irc, who)] = irc_model.new_member(irc_model.get_user(irc, who))
    end
end

-- "<client> <symbol> <channel> :[prefix]<nick>{ [prefix]<nick>}"
H[N.RPL_NAMREPLY] = function(_, irc, msg)
    local channel = irc_model.get_channel(irc, msg[3])
    if not channel then return end

    -- Prefixes come off before the userhost (userhost-in-names) does.
    -- ircc matched '[^!@ ]+' first, which dropped the @ prefix of ops.
    for word in msg[4]:gmatch '[^ ]+' do
        local entry = word
        local modes = {}
        while irc.prefix_to_mode[entry:sub(1, 1)] do
            modes[irc.prefix_to_mode[entry:sub(1, 1)]] = true
            entry = entry:sub(2)
        end
        entry = entry:match '^[^!@]*'
        channel.members[irc_model.fold(irc, entry)] =
            irc_model.new_member(irc_model.get_user(irc, entry), modes)
    end
end

function H.PART(_, irc, msg)
    local who = msg.nick
    local name = msg[1]
    if who == irc.nick then
        irc.channels[irc_model.fold(irc, name)] = nil
    else
        local channel = irc_model.get_channel(irc, name)
        if channel then
            channel.members[irc_model.fold(irc, who)] = nil
        end
    end
end

function H.KICK(_, irc, msg)
    local name = msg[1]
    local target = msg[2]
    if target == irc.nick then
        irc.channels[irc_model.fold(irc, name)] = nil
    else
        local channel = irc_model.get_channel(irc, name)
        if channel then
            channel.members[irc_model.fold(irc, target)] = nil
        end
    end
end

function H.QUIT(rec, irc, msg)
    local nick = msg.nick
    if not nick then return end
    local key = irc_model.fold(irc, nick)

    for _, channel in pairs(irc.channels) do
        channel.members[key] = nil
    end
    irc.users[key] = nil

    if want_nick(rec, irc, nick) then
        M.reclaim_nick(rec.id)
    end
end

function H.AWAY(_, irc, msg)
    if msg.nick then
        irc_model.get_user(irc, msg.nick).away = msg[1] -- nil when back
    end
end

-- "<client> <nick> :<message>"
H[N.RPL_AWAY] = function(_, irc, msg)
    irc_model.get_user(irc, msg[2]).away = msg[3]
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

    if target == irc.nick then
        parse_umodes(irc.mode, modestring)
        if irc.mode.o then now_oper(rec, irc) end
        return
    end

    if not irc_model.is_channel_name(irc, target) then return end
    local channel = irc_model.get_channel(irc, target)
    if not channel then return end -- mode information for a channel we aren't in

    local polarity = true
    for flag in modestring:gmatch '.' do
        if flag == '+' then
            polarity = true
        elseif flag == '-' then
            polarity = false
        elseif irc.mode_to_prefix[flag] then
            local member = irc_model.get_member(irc, channel, msg[cursor])
            cursor = cursor + 1
            if member then
                member.modes[flag] = polarity or nil
            end
        elseif irc.modes_A:find(flag, 1, true) then
            local modes = channel.list_modes[flag]
            local mask = msg[cursor]
            cursor = cursor + 1
            if modes then
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
        local list = irc.partial_mode_list or {}
        irc.partial_mode_list = list
        list[msg[mask_index]] = {who = msg[mask_index + 1], ts = msg[mask_index + 2]}
    end
end

local function list_end(mode)
    return function(_, irc, msg)
        local channel = irc_model.get_channel(irc, msg[2])
        if channel then
            channel.list_modes[mode] = irc.partial_mode_list or {}
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
H[N.RPL_CHANNELMODEIS] = function(_, irc, msg)
    local channel = irc_model.get_channel(irc, msg[2])
    if not channel then return end
    local cursor = 4
    local modes = {}
    channel.modes = modes
    for flag in msg[3]:gmatch '.' do
        if irc.modes_B:find(flag, 1, true) or irc.modes_C:find(flag, 1, true) then
            modes[flag] = msg[cursor]
            cursor = cursor + 1
        elseif irc.modes_D:find(flag, 1, true) then
            modes[flag] = true
        end
    end
end

H[N.RPL_UMODEIS] = function(rec, irc, msg)
    local modes = {}
    parse_umodes(modes, msg[2])
    irc.mode = modes
    if modes.o then now_oper(rec, irc) end
end

-----------------------------------------------------------------------
-- Accounts and SASL

-- <client> <mechanisms> :are available SASL mechanisms
H[N.RPL_SASLMECHS] = function(_, irc, msg)
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

    local network = irc.bouncer_networks[netid]
    if nil == network then
        network = {}
        irc.bouncer_networks[netid] = network
    end
    for k, v in pairs(snowcone.parse_irc_tags(attrs)) do
        -- no value indicates the attribute was deleted
        if true == v then
            network[k] = nil
        else
            network[k] = v
        end
    end
end

M.routes = {
    ['net.reclaim_nick'] = M.reclaim_nick,
}

return M
