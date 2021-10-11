local class = require 'pl.class'
local OrderedMap = class()
OrderedMap._name = 'OrderedMap'

function OrderedMap:insert(key, val)
    local m = self.max
    local n = self.n
    local i = n%m + 1
    self.n = n + 1

    if self.index[self.keys[i]] == i then
        self.index[self.keys[i]] = nil
    end

    self.keys[i] = key
    self.vals[i] = val
    self.index[key] = i
end

function OrderedMap:lookup(key)
    return self.vals[self.index[key]]
end

function OrderedMap:rekey(old, new)
    local i = self.index[old]
    if i then
        self.index[old] = nil
        self.keys[i] = new
        self.index[new] = i
    end
end

function OrderedMap:each()
    local i = 0
    local n = self.n
    local m = self.max
    local t = math.min(n,m)
    local function gen()
        if i < t then
            i = i + 1
            local j = (n-i)%m+1
            return self.keys[j], self.vals[j]
        end
    end

    return gen
end

function OrderedMap:_init(n)
    self.index = {}
    self.keys = {}
    self.vals = {}
    self.n = 0
    self.max = n
end

return OrderedMap
