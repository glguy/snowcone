local class = require 'pl.class'

local M = class()
M._name = 'NetTracker'

local MaskTracker = require_ 'components.MaskTracker'

function M:_init()
    self.masks = {}
end

function M:track(label, address, prefix)
    self.masks[label] = MaskTracker(address, prefix)
end

function M:set(label, count)
    local mask = self.masks[label]
    if mask then
        mask.count = count
    end
end

function M:delta(address, i)
    for _, mask in pairs(self.masks) do
        if mask:match(address) then
            mask:delta(i)
            return
        end
    end
end

function M:count()
    local n = 0
    for _, mask in pairs(self.masks) do
        n = n + mask.count
    end
    return n
end

return M
