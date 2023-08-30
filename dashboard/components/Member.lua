local class = require 'pl.class'

local M = class()
M._name = 'Member'

function M:_init(user)
    self.user = user
    self.modes = {}
end

function M:__tostring()
    return 'Member: ' .. self.user.nick
end

return M