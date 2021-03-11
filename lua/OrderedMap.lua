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
    local node = self.index[key]
    if node then
        unlink_node(node)
    else
        node = {key = key, val = val}
        self.n = self.n + 1
        self.index[key] = node
    end
    link_after(self, node)
    return node.val
end

function OrderedMap:delete(key)
    local node = self.index[key]
    if node then
        self.index[key] = nil
        self.n = self.n - 1
        unlink_node(node)
    end
end

function OrderedMap:lookup(key)
    local node = self.index[key]
    if node then
        return node.val
    end
end

function OrderedMap:each()
    local function each_step(obj, prev)
        local node
        if prev then
            node = obj.index[prev].next
        else 
            node = obj.next
        end
        return node.key, node.val
    end
    
    return each_step, self
end

function OrderedMap:_init()
    self.next = self
    self.prev = self
    self.index = {}
    self.n = 0
end

return OrderedMap
