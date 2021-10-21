local class = require 'pl.class'

local M = class()
M._name = 'Editor'

function M:_init()
    self.buffer = {}
    self.cursor = 1
    self:render()
end

function M:render()
    self.before_cursor = utf8.char(table.unpack(self.buffer, 1, self.cursor - 1))
    self.at_cursor = utf8.char(table.unpack(self.buffer, self.cursor))
    self.rendered = self.before_cursor .. self.at_cursor
end

function M:reset()
    self.buffer = {}
    self.cursor = 1
    self:render()
end

function M:is_empty()
    return self.rendered == ''
end

function M:backspace()
    if self.cursor > 1 then
        self.cursor = self.cursor - 1
        table.remove(self.buffer, self.cursor)
        self:render()
    end
end

function M:kill_to_beg()
    self.buffer = {table.unpack(self.buffer, self.cursor)}
    self.cursor = 1
    self:render()
end

function M:kill_to_end()
    self.buffer = {table.unpack(self.buffer, 1, self.cursor - 1)}
    self:render()
end

function M:add(code)
    table.insert(self.buffer, self.cursor, code)
    self.cursor = self.cursor + 1
    self:render()
end

function M:move_to_beg()
    self.cursor = 1
    self:render()
end

function M:move_to_end()
    self.cursor = #self.buffer + 1
    self:render()
end

function M:left()
    if self.cursor > 1 then
        self.cursor = self.cursor - 1
        self:render()
    end
end

function M:right()
    if self.cursor <= #self.buffer then
        self.cursor = self.cursor + 1
        self:render()
    end
end

return M