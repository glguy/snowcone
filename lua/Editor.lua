local class = require 'pl.class'

local M = class()
M._name = 'Editor'

function M:_init()
    self.buffer = {}
    self.cursor = 1
end

function M:render()
    return utf8.char(table.unpack(self.buffer))
end

function M:reset()
    self.buffer = {}
    self.cursor = 1
end

function M:is_empty()
    return #self.buffer == 0
end

function M:backspace()
    if self.cursor > 1 then
        self.cursor = self.cursor - 1
        table.remove(self.buffer, self.cursor)
    end
end

function M:kill_to_beg()
    local t = {}
    table.move(self.buffer, self.cursor, #self.buffer, 1, t)
    self.buffer = t
    self.cursor = 1
end

function M:kill_to_end()
    local t = {}
    table.move(self.buffer, 1, self.cursor - 1, 1, t)
    self.buffer = t
end

function M:add(code)
    table.insert(self.buffer, self.cursor, code)
    self.cursor = self.cursor + 1
end

function M:move_to_beg()
    self.cursor = 1
end

function M:move_to_end()
    self.cursor = #self.buffer + 1
end

function M:left()
    if self.cursor > 1 then
        self.cursor = self.cursor - 1
    end
end

function M:right()
    if self.cursor <= #self.buffer then
        self.cursor = self.cursor + 1
    end
end

return M