local class = require 'pl.class'

local M = class()
M._name = 'MaskTracker'

function M:_init(network, prefix)
    local bytes = prefix // 8
    self.network = string.sub(network, 1, bytes)
    local bits = prefix % 8
    if bits > 0 then
        self.tailmask = 0x100 - (0x100 >> bits)
        self.tail = network[bytes+1]
        self.tailix = bytes+1
    end
    self.count = 0
end

function M:match(address)
    return self.addrlen == #address
       and address:startswith(self.network)
       and (not self.tail
            or (address[self.tailix] & self.tailmask) == self.tail)
end

function M:delta(i)
    self.count = self.count + i
end

return M
