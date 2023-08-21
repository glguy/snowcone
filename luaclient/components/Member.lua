local class = require 'pl.class'

local M = class()
M._name = 'Member'

function M:_init(info)
    self.info = info
    self.modes = {}
end

function M:__tostring()
    return 'Member: ' .. self.info.nick
end

return M