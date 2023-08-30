local class = require 'pl.class'

local M = class()
M._name = 'User'

function M:_init(nick)
    self.nick = nick
end

function M:__tostring()
    return 'User: ' .. self.nick
end

return M