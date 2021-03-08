local class = require 'pl.class'
local LoadAverage = require 'LoadAverage'
local LoadTracker = class()
LoadTracker._name = 'LoadTracker'

function LoadTracker:track(name)
    self.events[name] = (self.events[name] or 0) + 1
end
function LoadTracker:tick()
    for name, _ in pairs(self.events) do
        if not self.detail[name] then
            self.detail[name] = LoadAverage()
        end
    end
    local total = 0
    for name, avg in pairs(self.detail) do
        local n = self.events[name] or 0
        avg:sample(n)
        total = total + n
    end
    self.events = {}
    self.global:sample(total)
end

function LoadTracker:_init()
    self.events = {}
    self.global = LoadAverage()
    self.detail = {}
end

return LoadTracker