local load_average = require 'load_average'

local M = {}

local load_tracker_methods = {
    track = function(self, name)
        self.events[name] = (self.events[name] or 0) + 1
    end,
    tick = function(self)
        for name, _ in pairs(self.events) do
            if not self.detail[name] then
                self.detail[name] = load_average.new()
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
}

local load_tracker_mt = {
    __name = 'load_tracker',
    __index = load_tracker_methods,
}

function M.new()
    local o = {events={}, global=load_average.new(), detail={}}
    setmetatable(o, load_tracker_mt)
    return o
end

return M