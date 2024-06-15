local class = require 'pl.class'

local M = class()
M._name = 'NotificationManager'


function M:_init()
    self.muted = {}
end

function M:load(module)
    if module then
        self.impl = require(module)
    else
        self.impl = nil
    end
end

function M:notify(target, nick, text)
    local key = snowcone.irccase(target)
    if not terminal_focus
    and self.impl then
        local previous = self.muted[key]
        self.muted[key] = self.impl.notify(previous, target, nick, text)
    end
end

function M:dismiss(target)
    local impl = self.impl
    if impl then
        local key = self.muted[target]
        if key then
            impl.dismiss(key)
            self.muted[key] = nil
        end
    end
end

return M
