local class = require 'pl.class'

local M = class()
M._name = 'Editor'

function M:_init()
    self.buffer = {}
    self.cursor = 1
    self.yank = {}
    self.yanking = false
    self:render()
end

function M:move(x)
    self.cursor = x
    self.yanking = false
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
    self.yanking = false
    self:render()
end

function M:is_empty()
    return self.rendered == ''
end

function M:backspace()
    if self.cursor > 1 then
        self.cursor = self.cursor - 1
        table.remove(self.buffer, self.cursor)
        self.yanking = false
        self:render()
    end
end

function M:kill_to_beg()
    if self.yanking then
        local t = {table.unpack(self.buffer, 1, self.cursor - 1)}
        table.move(self.yank, 1, #self.yank, #t + 1, t)
        self.yank = t
    else
        self.yank = {table.unpack(self.buffer, 1, self.cursor - 1)}
        self.yanking = true
    end

    self.buffer = {table.unpack(self.buffer, self.cursor)}
    self.cursor = 1
    self:render()
end

function M:kill_to_end()
    if self.yanking then
        table.move(self.buffer, self.cursor, #self.buffer, #self.yank + 1, self.yank)
    else
        self.yank = {table.unpack(self.buffer, self.cursor)}
        self.yanking = true
    end

    self.buffer = {table.unpack(self.buffer, 1, self.cursor - 1)}
    self:render()
end

function M:add(code)
    table.insert(self.buffer, self.cursor, code)
    self.cursor = self.cursor + 1
    self.yanking = false
    self:render()
end

function M:move_to_beg()
    self:move(1)
end

function M:move_to_end()
    self:move(#self.buffer + 1)
end

function M:left()
    if self.cursor > 1 then
        self:move(self.cursor - 1)
    end
end

function M:right()
    if self.cursor <= #self.buffer then
        self:move(self.cursor + 1)
    end
end

function M:paste()
    local t = {table.unpack(self.buffer, 1, self.cursor - 1)}
    table.move(self.yank, 1, #self.yank, #t + 1, t)
    table.move(self.buffer, self.cursor, #self.buffer, #t + 1, t)
    self.buffer = t
    self:move(self.cursor + #self.yank)
end

return M
