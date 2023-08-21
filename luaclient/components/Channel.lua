local class = require 'pl.class'

local M = class()
M._name = 'Channel'

function M:_init(name)
    self.name = name
    self.members = {}
    -- self.topic
    -- self.creationtime
end

function M:__tostring()
    return 'Channel: ' .. self.name
end

function M:get_member(nick)
    return self.members[snowcone.irccase(nick)]
end

return M