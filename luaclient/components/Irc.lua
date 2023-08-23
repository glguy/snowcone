local class = require 'pl.class'
local User = require  'components.User'

-- irc_state
-- .caps_ls        - set of string   - create in LS - consume at end of LS
-- .caps_list      - array of string - list of enabled caps - consume after LIST
-- .caps_available - set of string   - created by LS and NEW
-- .caps_wanted    - set of string   - create before LS - consume after ACK/NAK
-- .caps_enabled   - set of string   - filled by ACK
-- .caps_requested - set of string   - create on LS or NEW - consume at ACK or NAK
-- .phase          - string          - registration or connected
-- .sasl           - coroutine       - AUTHENTICATE state machine
-- .nick           - string          - current nickname
-- .authenticate   - array of string - accumulated chunks of AUTHENTICATE
-- .challenge      - array of string - accumulated chunks of CHALLENGE
-- .monitor
-- .chantypes
-- .batches
-- .isupport

local M = class()
M._name = 'Irc'

local function make_user_table()
    local MT = { __mode = 'v' } -- weak values
    local tab = {}
    setmetatable(tab, MT)
    return tab
end

function M:_init()
    self.phase = 'registration' -- registration, connected, closed
    self.caps_wanted = {}
    self.caps_enabled = {}
    self.caps_available = {}
    self.caps_requested = {}

    self.isupport = {}

    self.batches = {}
    self.channels = {}

    self.chantypes = '&#' -- updated by ISUPPORT
    self.monitor = nil -- map irccased nickname mapped to {nick=str, online=bool}
    self.max_chat_history = nil

    self.prefix_to_mode = { ["@"] = "o", ["+"] = "v"}
    self.mode_to_prefix = { ["o"] = "@", ["v"] = "+"}
    self.modes_A = '' -- Modes that add or remove an address to or from a list.
    self.modes_B = '' -- Modes that change a setting on a channel. Arg always set
    self.modes_C = '' -- Modes that change a setting on a channel. Arg when set
    self.modes_D = '' -- Modes that change a setting on a channel. Arg never

    self.users = make_user_table()
end

-- gets run at end of registration and should be the last time
-- normal behavior relies on the raw isupport
function M:commit_isupport()
    local isupport = irc_state.isupport

    -- CHANTYPES
    self.chantypes = isupport.CHANTYPES or self.chantypes
    if isupport.MONITOR then
        self.monitor = {}
    end

    -- PREFIX
    if isupport.PREFIX then
        local modes, prefixes = isupport.PREFIX:match '^%((.*)%)(.*)$'
        local prefix_to_mode, mode_to_prefix = {}, {}
        for i = 1, #modes do
            local prefix, mode = prefixes:sub(i,i), modes:sub(i,i)
            prefix_to_mode[prefix] = mode
            mode_to_prefix[mode] = prefix
        end
        self.prefix_to_mode = prefix_to_mode
        self.mode_to_prefix = mode_to_prefix
    end

    -- CHANMODES
    if isupport.CHANMODES then
        self.modes_A, self.modes_B, self.modes_C, self.modes_D =
            isupport.CHANMODES:match '^([^,]*),([^,]*),([^,]*),([^,]*)'
    end

    -- CHATHISTORY
    local n = tonumber(self.isupport.CHATHISTORY)
    -- 0 indicates "no limit"
    if n ~= nil and n > 0 then
        self.max_chat_history = n
    end
end

function M:get_monitor(nick)
    return self.monitor[snowcone.irccase(nick)]
end

function M:get_user(nick)
    local key = snowcone.irccase(nick)
    local entry = self.users[key]
    if not entry then
        entry = User(nick)
        self.users[key] = entry
    end
    return entry
end

function M:add_monitor(nick, online)
    if online then
        self.monitor[snowcone.irccase(nick)] = {
            user = self:get_user(nick)
        }
    else
        self.monitor[snowcone.irccase(nick)] = {}
    end
end

function M:has_monitor()
    return self.monitor ~= nil
end

function M:is_monitored(nick)
    return self:get_monitor(nick) ~= nil
end

function M:is_channel_name(name)
    local sigil = name:sub(1,1)
    return string.find(self.chantypes, sigil, 1, true) and sigil ~= ''
end

function M:has_chathistory()
    return self.caps_enabled['draft/chathistory']
end

function M:get_channel(name)
    return self.channels[snowcone.irccase(name)]
end

function M:get_partial_mode_list()
    local mode_list = self.partial_mode_list
    if not mode_list then
        mode_list = {}
        self.partial_mode_list = mode_list
    end
    return mode_list
end

function M:clear_partial_mode_list()
    self.partial_mode_list = nil
end

return M
