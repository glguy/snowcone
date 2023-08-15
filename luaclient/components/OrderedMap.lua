local class = require 'pl.class'
local OrderedMap = class()
OrderedMap._name = 'components.OrderedMap'

function OrderedMap:insert(key, val)
    local m = self.max
    local n = self.n
    local i = n%m + 1
    self.n = n + 1

    -- Overwriting old entry, remove from index if needed
    if self:getindex(self.keys[i]) == i then
        self:setindex(self.keys[i])
    end

    -- Remember new index
    if key ~= nil then
        self:setindex(key, i)
    end

    self.keys[i] = key
    self.vals[i] = val

    local p = self.predicate
    if p == nil or p(val) then
        self.ticker = self.ticker + 1
    end
end

function OrderedMap:lookup(key)
    return self.vals[self:getindex(key)]
end

function OrderedMap:rekey(old, new)
    local i = self:getindex(old)
    if i ~= nil then
        self:setindex(old)
        self.keys[i] = new
        self:setindex(new, i)
    end
end

function OrderedMap:each(offset)
    local i = offset or 0
    local n = self.n
    local m = self.max
    local t = math.min(n,m)
    local function gen()
        if i < t then
            i = i + 1
            local j = (n-i)%m+1
            return self.vals[j], self.keys[j]
        end
    end

    return gen
end

function OrderedMap:setindex(key, i)
    local f = self.keyfn
    if f then
        self.index[f(key)] = i
    else
        self.index[key] = i
    end
end

function OrderedMap:getindex(key)
    if key == nil then return end
    local f = self.keyfn
    if f then
        return self.index[f(key)]
    else
        return self.index[key]
    end
end

function OrderedMap:_init(n, keyfn)
    self.index = {}
    self.keys = {}
    self.vals = {}
    self.n = 0
    self.max = n
    self.ticker = 0
    self.keyfn = keyfn
    self.seen = 0
end

return OrderedMap
