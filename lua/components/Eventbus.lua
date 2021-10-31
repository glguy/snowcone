local class = require 'pl.class'

local M = class()
M._name = 'Eventbus'

function M:_init()
    self.handlers = {}
end

function M:on(name, handler)
    local t = self.handlers[name]
    if t == nil then
        self.handlers[name] = {[handler] = true}
    else
        t[handler] = true
    end
end

function M:off(name, handler)
    local t = self.handlers[name]
    if t ~= nil then
        t[handler] = nil
        if next(t) == nil then
            self.handlers[name] = nil
        end
    end
end

function M:emit(name, ...)
    for h in pairs(self.handlers[name] or {}) do
        h(...)
    end
end

return M