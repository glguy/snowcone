local class = require 'pl.class'
local OrderedMap = class()
OrderedMap._name = 'OrderedMap'

local function unlink_node(node)
    local p = node.prev
    local q = node.next
    p.next = q
    q.prev = p
end

local function link_after(p, node)
    local q = p.next
    p.next = node
    node.next = q
    q.prev = node
    node.prev = p
end

function OrderedMap:first_key()
    if self.n > 0 then
        return self.next.key
    end
end

function OrderedMap:last_key()
    if self.n > 0 then
        return self.prev.key
    end
end

function OrderedMap:insert(key, val)
    local node = {key = key, val = val}
    self.n = self.n + 1
    self.index[key] = node
    link_after(self, node)
end

function OrderedMap:delete(key)
    local node = self.index[key]
    if node then
        self.index[key] = nil
        self.n = self.n - 1
        unlink_node(node)
    end
end

function OrderedMap:pop_back()
    if self.n > 0 then
        local node = self.prev
        local key = node.key
        if self.index[key] == node then
            self.indix[key] = nil
        end
        unlink_node(node)
    end
end

function OrderedMap:lookup(key)
    local node = self.index[key]
    if node then
        return node.val
    end
end

function OrderedMap:rekey(old, new)
    self:delete(new)
    local node = self.index[old]
    if node then
        node.key = new
        self.index[old] = nil
        self.index[new] = node
    end
end

function OrderedMap:each()
    local node = self
    local function gen()
        local node1 = node.next
        if node1 ~= self then
            node = node1
            return node.key, node.val
        end
    end

    return gen
end

function OrderedMap:_init()
    self.next = self
    self.prev = self
    self.index = {}
    self.n = 0
end

return OrderedMap
