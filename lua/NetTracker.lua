local class = require 'pl.class'

local NetTracker = class()
NetTracker._name = 'NetTracker'

function NetTracker:_init(label, network, prefix)
    self.label = label
    self.prefix = string.sub(network, 1, prefix/8)
    self.addrlen = #network
    self.count = 0
end

function NetTracker:match(address)
    return self.addrlen == #address and address:startswith(self.prefix)
end

function NetTracker:inc()
    self.count = self.count + 1
end

function NetTracker:dec()
    self.count = self.count - 1
end

return NetTracker
