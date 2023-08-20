local class = require 'pl.class'

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
-- .target_nick    - string          - consumed when target nick recovered
-- .authenticate   - array of string - accumulated chunks of AUTHENTICATE
-- .challenge      - array of string - accumulated chunks of CHALLENGE
-- .monitor
-- .chantypes
-- .batches

local M = class()
M._name = 'Irc'

function M:_init()
    self.phase = 'registration' -- registration, connected, closed
    self.caps_wanted = {}
    self.caps_enabled = {}
    self.caps_available = {}
    self.caps_requested = {}
    self.batches = {}
    self.channels = {}
    self.chantypes = '&#' -- updated by ISUPPORT
    self.monitor = {} -- map irccased nickname mapped to {nick=str, online=bool}
end

function M:get_monitor(nick)
    return self.monitor[snowcone.irccase(nick)]
end

function M:add_monitor(nick, online)
    self.monitor[snowcone.irccase(nick)] = {
        nick = nick,
        online = online,
    }
end

function M:has_monitor()
    return self.isupport.MONITOR ~= nil
end

function M:is_monitored(nick)
    local entry = self:get_monitor(nick)
    return entry and entry.online ~= nil
end

function M:is_channel_name(name)
    local sigil = name:sub(1,1)
    local chantypes = self.isupport.CHANTYPES or '#&'
    return string.find(sigil, chantypes, 1, true) and sigil ~= ''
end

function M:has_chathistory()
    return self.caps_enabled['draft/chathistory']
end

function M:max_chat_history()
    local n = tonumber(self.isupport.CHATHISTORY)
    -- 0 indicates "no limit"
    if n ~= nil and n > 0 then
        return n
    end
end

return M
