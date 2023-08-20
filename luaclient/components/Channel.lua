local class = require 'pl.class'

local M = class()
M._name = 'Channel'

function M:_init(name)
    self.name = name
    -- self.topic
    -- self.creationtime
end

function M:__tostring()
    return 'Channel: ' .. self.name
end

return M