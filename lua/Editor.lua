local class = require 'pl.class'
local tablex = require 'pl.tablex'

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
        local t = tablex.sub(self.buffer, 1, self.cursor - 1)
        table.move(self.yank, 1, #self.yank, #t + 1, t)
        self.yank = t
    else
        self.yank = tablex.sub(self.buffer, 1, self.cursor - 1)
        self.yanking = true
    end

    self.buffer = tablex.sub(self.buffer, self.cursor, -1)
    self.cursor = 1
    self:render()
end

function M:kill_to_end()
    if self.yanking then
        table.move(self.buffer, self.cursor, #self.buffer, #self.yank + 1, self.yank)
    else
        self.yank = tablex.sub(self.buffer, self.cursor, -1)
        self.yanking = true
    end
    tablex.removevalues(self.buffer, self.cursor, - 1)
    self:render()
end

function M:kill_region()
    local i = self.cursor - 1

    -- pass over the spaces
    while i > 0 and self.buffer[i] == 0x20 do
        i = i - 1
    end

    -- pass over the non-spaces
    while i > 0 and self.buffer[i] ~= 0x20 do
        i = i - 1
    end

    -- point at the last non-space
    i = i + 1

    -- extract that region
    local region = tablex.sub(self.buffer, i, self.cursor - 1)
    tablex.removevalues(self.buffer, i, self.cursor - 1)

    if self.yanking then
        tablex.insertvalues(self.yank, 1, region)
    else
        self.yank = region
        self.yanking = true
    end

    self.cursor = i
    self:render()
end

function M:add(code)
    table.insert(self.buffer, self.cursor, code)
    self.cursor = self.cursor + 1
    self.yanking = false
    self:render()
end

function M:swap()
    local n = #self.buffer
    if n > 1 then
        if self.cursor == 1 then
            self.cursor = 3
        elseif self.cursor <= n then
            self.cursor = self.cursor + 1
        end
        local t = self.buffer[self.cursor - 2]
        self.buffer[self.cursor - 2] = self.buffer[self.cursor - 1]
        self.buffer[self.cursor - 1] = t
        self:render()
        self.yanking = false
    end
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
    tablex.insertvalues(self.buffer, self.cursor, self.yank)
    self:move(self.cursor + #self.yank)
    self.yanking = false
end

return M
