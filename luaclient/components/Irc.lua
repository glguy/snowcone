local class = require 'pl.class'
local Set = require 'pl.Set'

local M = class()
M._name = 'Irc'

function M:_init()
    self.phase = 'registration' -- registration, connected, closed
    self.caps_wanted = Set{}
    self.caps_enabled = Set{}
    self.caps_available = Set{}
    self.caps_requested = Set{}
    self.batches = {}
    self.channels = {}
    self.chantypes = '&#' -- updated by ISUPPORT
    self.monitor = {} -- map irccased nickname mapped to {nick=str, online=bool}
end

function M:is_channel_name(name)
    local sigil = name:sub(1,1)
    return string.find(sigil, self.chantypes, 1, true) and sigil ~= ''
end

function M:has_chathistory()
    return self.caps_enabled['draft/chathistory']
end

return M
