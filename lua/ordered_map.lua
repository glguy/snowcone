local M = {}

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

local ordered_map_methods = {
    first_key = function(self)
        if self.n > 0 then
            return self.next.key
        end
    end,

    last_key = function(self)
        if self.n > 0 then
            return self.prev.key
        end
    end,

    insert = function(self, key, val)
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
    end,

    delete = function(self, key)
        local node = self.index[key]
        if node then
            self.index[key] = nil
            self.n = self.n - 1
            unlink_node(node)
        end
    end,

    lookup = function(self, key)
        local node = self.index[key]
        if node then
            return node.val
        end
    end,

    each = function(self)
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
    end,
}

local ordered_map_mt = {
    __index = ordered_map_methods,
    __name = "ordered_map",
}

function M.new()
    local obj = {index = {}, n = 0}
    obj.next = obj
    obj.prev = obj
    setmetatable(obj, ordered_map_mt)
    return obj
end

return M