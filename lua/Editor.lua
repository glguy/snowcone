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

function M:kill_prev_word()
    local i = self:search_prev_word()
    local j = self.cursor - 1

    -- extract that region
    local region = tablex.sub(self.buffer, i, j)
    tablex.removevalues(self.buffer, i, j)

    if self.yanking then
        tablex.insertvalues(self.yank, 1, region)
    else
        self.yank = region
        self.yanking = true
    end

    self.cursor = i
    self:render()
end


function M:kill_next_word()
    local i = self.cursor
    local j = self:search_next_word() - 1

    -- extract that region
    local region = tablex.sub(self.buffer, i, j)
    tablex.removevalues(self.buffer, i, j)

    if self.yanking then
        tablex.insertvalues(self.yank, #self.yank + 1, region)
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

function M:move_left()
    if self.cursor > 1 then
        self:move(self.cursor - 1)
    end
end

function M:move_right()
    if self.cursor <= #self.buffer then
        self:move(self.cursor + 1)
    end
end

function M:move_next_word()
    self:move(self:search_next_word())
end

function M:move_prev_word()
    self:move(self:search_prev_word())
end

function M:search_next_word()
    local i = self.cursor
    local b = self.buffer
    local n = #b
    if i <= n then
        i = i + 1
        while i <= n and (b[i-1] == 0x20 or b[i] ~= 0x20) do
            i = i + 1
        end
    end
    return i
end

function M:search_prev_word()
    local i = self.cursor
    local b = self.buffer
    if 1 < i then
        i = i - 1
    end
    while 1 < i and b[i] == 0x20 do
        i = i - 1
    end
    while 1 < i and b[i-1] ~= 0x20 do
        i = i - 1
    end
    return i
end

function M:paste()
    tablex.insertvalues(self.buffer, self.cursor, self.yank)
    self:move(self.cursor + #self.yank)
    self.yanking = false
end

return M
