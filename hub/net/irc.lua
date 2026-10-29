-- The protocol model of one IRC connection, as plain records and
-- functions.
--
-- The model is a field of the network record, state.nets[id].irc, and
-- exists while a connection does. Nick and channel keys are folded with the
-- network's casemapping, which ISUPPORT CASEMAPPING selects.
--
-- irc.users holds weak values: a user stays while a channel member or a
-- monitor entry refers to it. That metatable carries no code, so it is
-- safe across reloads.

local bus     <const> = require 'hub.runtime.bus'
local casemap <const> = require 'hub.lib.casemap'

local M = {}

-- Capabilities requested by default; a network's `server.capabilities`
-- adds names, or removes them with a leading -. draft/event-playback is
-- left out on purpose: it replays joins and parts along with chat.
M.caps_supported = {
    'account-notify',
    'account-tag',
    'away-notify',
    'batch',
    'cap-notify',
    'chghost',
    'draft/chathistory',
    'extended-join',
    'extended-monitor',
    'invite-notify',
    'message-tags',
    'multi-prefix',
    'sasl',
    'server-time',
    'setname',
    'soju.im/bouncer-networks',
    'soju.im/bouncer-networks-notify',
    'solanum.chat/identify-msg',
    'solanum.chat/oper',
    'solanum.chat/realhost',
}

---@return hub.Irc # a new model for a connection that hasn't registered
function M.new()
    ---@class hub.Irc
    ---@field nick string|nil ours, once registered
    ---@field caps_wanted table<string, true>
    ---@field caps_enabled table<string, true>
    ---@field caps_available table<string, string|true> value, or true without one
    ---@field isupport table<string, string|true>
    ---@field batches table<string, hub.Batch> open batches by name
    ---@field channels table<string, hub.Channel> by folded name
    ---@field users table<string, hub.User> by folded nick, weak values
    ---@field mode table<string, true> our user modes
    ---@field account string|nil ours, once logged in
    ---@field oper boolean|nil
    ---@field snomask string|nil
    ---@field recover_nick string|nil folded nick to take back when it frees up
    ---@field sasl_credentials table|nil the credentials registration chose
    ---@field partial_mode_list table<string, hub.ListEntry>|nil a list mode
    --- being received
    ---@field sasl_mechs table<string, true>|nil
    ---@field monitor table<string, {user: hub.User|nil}>|nil by folded nick
    ---@field max_chat_history integer|nil
    ---@field invex string|nil
    ---@field excepts string|nil
    ---@field bouncer_networks table<string, table<string, string>>|nil by netid
    local irc = {
        kind = 'Irc',
        casemapping = 'rfc1459',

        caps_wanted = {},
        caps_enabled = {},
        caps_available = {},
        sasl_mechs = nil, -- set of names, nil when unknown

        isupport = {},
        batches = {},
        channels = {},
        mode = {},
        users = setmetatable({}, {__mode = 'v'}),

        linelen = 512, -- updated by ISUPPORT
        chantypes = '&#', -- updated by ISUPPORT
        monitor = nil, -- [folded nick] = {user = user or nil}, when MONITOR is supported
        max_chat_history = nil,

        statusmsg = '@+',
        prefix_to_mode = {['@'] = 'o', ['+'] = 'v'},
        mode_to_prefix = {o = '@', v = '+'},
        modes_A = '', -- Modes that add or remove an address to or from a list.
        modes_B = '', -- Modes that change a setting on a channel. Arg always set
        modes_C = '', -- Modes that change a setting on a channel. Arg when set
        modes_D = '', -- Modes that change a setting on a channel. Arg never
    }
    for _, cap in ipairs(M.caps_supported) do
        irc.caps_wanted[cap] = true
    end
    return irc
end

---@class hub.User
---@field nick string
---@field away string|nil the away message

---@class hub.Channel
---@field name string
---@field members table<string, hub.Member> by folded nick
---@field list_modes table<string, table<string, hub.ListEntry>> by mode, then mask
---@field modes table<string, string|true>|nil from RPL_CHANNELMODEIS: the
--- argument, or true without one
---@field topic string|nil
---@field creationtime number|nil

---@class hub.Member
---@field user hub.User
---@field modes table<string, true> prefix modes, like o and v

---@class hub.ListEntry
---@field who string|nil who set it
---@field ts string|nil when, as the server sent it

--- Fold a nick or channel name with the network's casemapping.
---@param irc hub.Irc
---@param name string
---@return string
function M.fold(irc, name)
    return casemap.fold(irc.casemapping, name)
end

-- ISUPPORT ===========================================================

local isupport_logic = {}

function isupport_logic.CASEMAPPING(irc, arg)
    if casemap.mappings[arg] then
        irc.casemapping = arg
    else
        irc.casemapping = 'rfc1459'
    end
end

function isupport_logic.CHANTYPES(irc, arg)
    irc.chantypes = arg or '&#'
end

function isupport_logic.LINELEN(irc, arg)
    irc.linelen = math.tointeger(arg) or 512
end

function isupport_logic.STATUSMSG(irc, arg)
    irc.statusmsg = arg or ''
end

function isupport_logic.MONITOR(irc, arg)
    if arg then
        irc.monitor = irc.monitor or {}
    else
        irc.monitor = nil
    end
end

function isupport_logic.INVEX(irc, arg)
    if arg == true then arg = 'I' end
    irc.invex = arg
end

function isupport_logic.EXCEPTS(irc, arg)
    if arg == true then arg = 'e' end
    irc.excepts = arg
end

function isupport_logic.PREFIX(irc, arg)
    local prefix_to_mode, mode_to_prefix = {}, {}
    local modes, prefixes = (arg or ''):match '^%((.*)%)(.*)$'
    if modes then
        for i = 1, #modes do
            local prefix, mode = prefixes:sub(i, i), modes:sub(i, i)
            prefix_to_mode[prefix] = mode
            mode_to_prefix[mode] = prefix
        end
    end
    irc.prefix_to_mode = prefix_to_mode
    irc.mode_to_prefix = mode_to_prefix
end

function isupport_logic.CHANMODES(irc, arg)
    local a, b, c, d = (arg or ''):match '^([^,]*),([^,]*),([^,]*),([^,]*)'
    irc.modes_A, irc.modes_B, irc.modes_C, irc.modes_D = a or '', b or '', c or '', d or ''
end

function isupport_logic.CHATHISTORY(irc, arg)
    local n = tonumber(arg)
    -- 0 indicates "no limit"
    if n ~= nil and n > 0 then
        irc.max_chat_history = n
    else
        irc.max_chat_history = nil
    end
end

--- Record an ISUPPORT token; val is nil when removed, true without a value.
---@param net string
---@param irc hub.Irc
---@param key string
---@param val string|true|nil
function M.set_isupport(net, irc, key, val)
    irc.isupport[key] = val
    local f = isupport_logic[key]
    if f then
        f(irc, val)
    end
    bus.emit('irc.isupport', {net = net, key = key, value = val})
end

-- Users, channels, monitor ===========================================

--- The user record for a nick, created when missing.
---@param irc hub.Irc
---@param nick string
---@return hub.User
function M.get_user(irc, nick)
    local key = M.fold(irc, nick)
    local user = irc.users[key]
    if not user then
        user = {nick = nick}
        irc.users[key] = user
    end
    return user
end

--- A nick is ours, compared with the network's casemapping (a server may
--- echo our nick in another case than we sent it).
---@param irc hub.Irc
---@param nick string|nil
---@return boolean
function M.is_me(irc, nick)
    return nick ~= nil and irc.nick ~= nil and M.fold(irc, nick) == M.fold(irc, irc.nick)
end

---@param irc hub.Irc
---@param name string
---@return hub.Channel|nil
function M.get_channel(irc, name)
    return irc.channels[M.fold(irc, name)]
end

---@param name string
---@return hub.Channel
function M.new_channel(name)
    return {name = name, members = {}, list_modes = {}}
end

---@param user hub.User
---@param modes table<string, true>|nil
---@return hub.Member
function M.new_member(user, modes)
    return {user = user, modes = modes or {}}
end

---@param irc hub.Irc
---@param channel hub.Channel
---@param nick string
---@return hub.Member|nil
function M.get_member(irc, channel, nick)
    return channel.members[M.fold(irc, nick)]
end

---@param irc hub.Irc
---@param name string
---@return boolean
function M.is_channel_name(irc, name)
    local sigil = name:sub(1, 1)
    return sigil ~= '' and string.find(irc.chantypes, sigil, 1, true) ~= nil
end

---@param irc hub.Irc
---@return boolean
function M.has_monitor(irc)
    return irc.monitor ~= nil
end

---@param irc hub.Irc
---@param nick string
---@return {user: hub.User|nil}|nil
function M.get_monitor(irc, nick)
    return irc.monitor and irc.monitor[M.fold(irc, nick)]
end

--- Track a monitored nick; online links its user record.
---@param irc hub.Irc
---@param nick string
---@param online boolean
function M.add_monitor(irc, nick, online)
    if online then
        irc.monitor[M.fold(irc, nick)] = {user = M.get_user(irc, nick)}
    else
        irc.monitor[M.fold(irc, nick)] = {}
    end
end

---@param irc hub.Irc
---@param nick string
function M.del_monitor(irc, nick)
    if irc.monitor then
        irc.monitor[M.fold(irc, nick)] = nil
    end
end

--- Split leading STATUSMSG prefixes off a target.
---@param irc hub.Irc
---@param target string
---@return string|nil prefix
---@return string target
function M.split_statusmsg(irc, target)
    ---@type string|nil
    local prefix = ''
    while target ~= '' and irc.statusmsg:find(target:sub(1, 1), 1, true) do
        prefix = prefix .. target:sub(1, 1)
        target = target:sub(2)
    end
    if prefix == '' then
        prefix = nil
    end
    return prefix, target
end

-- Capabilities =======================================================

--- Record the server's SASL mechanisms: a comma-separated list, or nil
--- when unknown.
---@param irc hub.Irc
---@param list string|nil
local function set_sasl_mechs(irc, list)
    if list then
        local set = {}
        for mech in list:gmatch '[^,]+' do
            set[mech] = true
        end
        irc.sasl_mechs = set
    else
        irc.sasl_mechs = nil
    end
end
M.set_sasl_mechs = set_sasl_mechs

--- Record capabilities from LS or NEW.
---@param irc hub.Irc
---@param capsarg string
---@return table<string, string|true> # each cap's value, or true without one
function M.add_caps(irc, capsarg)
    local caps = {}
    for cap, eq, arg in capsarg:gmatch '([^ =]+)(=?)([^ ]*)' do
        local cap_value = eq == '=' and arg or true
        irc.caps_available[cap] = cap_value
        caps[cap] = cap_value
        if 'sasl' == cap then
            set_sasl_mechs(irc, eq == '=' and arg or nil)
        end
    end
    return caps
end

---@param irc hub.Irc
---@param capsarg string
function M.del_caps(irc, capsarg)
    for cap in capsarg:gmatch '[^ ]+' do
        irc.caps_available[cap] = nil
        irc.caps_enabled[cap] = nil
        if 'sasl' == cap then
            set_sasl_mechs(irc, nil)
        end
    end
end

--- Apply `server.capabilities` from configuration: names to add, or remove
--- with a leading -
---@param irc hub.Irc
---@param list string[]|nil
function M.configure_caps(irc, list)
    for _, cap in ipairs(list or {}) do
        local minus, name = cap:match '^(%-?)([^ ]+)$'
        if minus == '-' then
            irc.caps_wanted[name] = nil
        elseif name ~= nil then
            irc.caps_wanted[name] = true
        end
    end
end

---@param irc hub.Irc
---@return true|nil
function M.has_sasl(irc)
    return irc.caps_enabled.sasl
end

--- A mechanism might be supported. When the server didn't list its
--- mechanisms, all of them might be.
---@param irc hub.Irc
---@param mech string
---@return boolean|nil
function M.has_sasl_mech(irc, mech)
    return not irc.sasl_mechs or irc.sasl_mechs[mech]
end

---@param irc hub.Irc
---@return true|nil
function M.has_chathistory(irc)
    return irc.caps_enabled['draft/chathistory']
end

return M
