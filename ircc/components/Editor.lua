local class = require 'pl.class'
local tablex = require 'pl.tablex'

local M = class()
M._name = 'Editor'

function M:_init()
    self.buffer = {}        -- Array[Code]
    self.history = {}       -- Array[Array[Code]]
    self.cursor = 1         -- Index into buffer
    self.retrospect = nil   -- Index into history
    self.stash = nil        -- Original buffer when retrospect ~= nil
    self.yank = {}          -- Array[Code]
    self.state = nil        -- edit(nil), kill, tab
    self.tablist = nil
    self.tabix = nil
    self:render()
end

function M:content()
    return utf8.char(table.unpack(self.buffer))
end

function M:size()
    return #self.buffer
end

function M:move(x, state)
    self.cursor = x
    self.state = state
    self:render()
end

function M:render()
    self.before_cursor = utf8.char(table.unpack(self.buffer, 1, self.cursor - 1))
    self.at_cursor = utf8.char(table.unpack(self.buffer, self.cursor))
end

function M:reset()
    self.buffer = {}
    self.retrospect = nil
    self.stash = nil
    self:move(1)
end

function M:confirm()
    local n = #self.history
    if n == 0 or not tablex.compare_no_order(self.history[n], self.buffer) then
        self.history[n+1] = self.buffer
    end
    self:reset()
end

function M:older_history()
    local r = self.retrospect
    local h = self.history

    if r ~= nil and 1 < r then
        if self.buffer[1] ~= nil then
            h[r] = self.buffer
        else
            table.remove(h, r)
        end
        r = r - 1

        self.buffer = tablex.copy(h[r])
        self.retrospect = r
        self:move_to_end()
    elseif r == nil and h[1] ~= nil then
        r = #h
        self.stash = self.buffer
        self.buffer = tablex.copy(h[r])
        self.retrospect = r
        self:move_to_end()
    end
end

function M:newer_history()
    local r = self.retrospect
    local h = self.history

    if r == nil then
        return
    end

    if self.buffer[1] ~= nil then
        h[r] = self.buffer
        r = r + 1
    else
        table.remove(h, r)
    end

    if h[r] == nil then
        self.buffer = self.stash
        self.stash = nil
        self.retrospect = nil
    else
        self.buffer = tablex.copy(h[r])
        self.retrospect = r
    end

    self:move_to_end()
end

function M:is_empty()
    return not self.buffer[1]
end

function M:backspace()
    local i = self.cursor
    if 1 < i then
        table.remove(self.buffer, i - 1)
        self:move(i - 1)
    end
end

function M:delete()
    table.remove(self.buffer, self.cursor)
    self.state = nil
    self:render()
end

function M:add_yank_left(lo, hi)
    local t = tablex.sub(self.buffer, lo, hi)
    if self.state == 'kill' then
        tablex.insertvalues(self.yank, 1, t)
    else
        self.yank = t
        self.state = 'kill'
    end
end

function M:kill_to_beg()
    self:add_yank_left(1, self.cursor - 1)
    self.buffer = tablex.sub(self.buffer, self.cursor, -1)
    self:move(1, 'kill')
end

function M:kill_to_end()
    if self.state == 'kill' then
        table.move(self.buffer, self.cursor, #self.buffer, #self.yank + 1, self.yank)
    else
        self.yank = tablex.sub(self.buffer, self.cursor, -1)
        self.state = 'kill'
    end
    tablex.removevalues(self.buffer, self.cursor, - 1)
    self:render()
end

function M:kill_prev_word()
    local i = self:search_prev_word()
    local j = self.cursor - 1

    self:add_yank_left(i, j)
    tablex.removevalues(self.buffer, i, j)
    self:move(i, 'kill')
end


function M:kill_next_word()
    local i = self.cursor
    local j = self:search_next_word() - 1

    -- extract that region
    local region = tablex.sub(self.buffer, i, j)
    tablex.removevalues(self.buffer, i, j)

    if self.state == 'kill' then
        tablex.insertvalues(self.yank, #self.yank + 1, region)
    else
        self.yank = region
        self.state = 'kill'
    end

    self:move(i, 'kill')
end

function M:add(code)
    table.insert(self.buffer, self.cursor, code)
    self:move(self.cursor + 1)
end

function M:swap()
    local n = #self.buffer
    local i = self.cursor
    if n > 1 then
        if i == 1 then
            i = 3
        elseif i <= n then
            i = i + 1
        end
        local t = self.buffer[i - 2]
        self.buffer[i - 2] = self.buffer[i - 1]
        self.buffer[i - 1] = t
        self:move(i)
    end
end

local hexdigits = {
    [48] = 0,
    [49] = 1,
    [50] = 2,
    [51] = 3,
    [52] = 4,
    [53] = 5,
    [54] = 6,
    [55] = 7,
    [56] = 8,
    [57] = 9,
    [65] = 10, [97] = 10,
    [66] = 11, [98] = 11,
    [67] = 12, [99] = 12,
    [68] = 13, [100] = 13,
    [69] = 14, [101] = 14,
    [70] = 15, [102] = 15,
}

-- Look for sequences of 'x' and then hex digits just before the cursor
function M:hexinput()
    local b = self.buffer
    local last = self.cursor - 1

    -- Support ^A style control characters
    if 1 < last
    and b[last - 1] == 0x5e -- '^'
    then
        local c = b[last]
        if 0x41 <= c and c <= 0x5f and c ~= 10 and c ~= 13 -- A-M O-Q S-Z [ \ ] ^ _
        then
            b[last - 1] = c - 0x40 -- replaces the '^' with control character
            table.remove(b, last)
            self:move(last)
            return
        end
    end

    -- Support x0123 style unicode values
    -- Find the value of i such than i points at: x[0-9a-fA-F]+
    local first = last
    while 1 < first do
        if b[first - 1] == 120 then -- check for 'x'

            -- Compute new value
            local acc = 0
            for j = first, last do
                acc = 16 * acc + hexdigits[b[j]]
            end

            -- ensure value is valid for the input buffer
            if acc == 0 or acc == 10 or acc == 13 or acc > 0x10ffff then return end

            -- replace escape sequence with value
            tablex.removevalues(b, first, last)
            b[first - 1] = acc -- replaces the 'x'

            self:move(first)
            return -- done
        elseif hexdigits[b[first - 1]] then
            first = first - 1
        else
            return -- bad sequence
        end
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
    local p = snowcone.isalnum
    local i = self.cursor
    local b = self.buffer
    local n = #b
    if i <= n then
        i = i + 1
        while i <= n and (not p(b[i-1]) or p(b[i])) do
            i = i + 1
        end
    end
    return i
end

function M:search_prev_word(p)
    p = p or snowcone.isalnum
    local i = self.cursor
    local b = self.buffer
    if 1 < i then
        i = i - 1
    end
    while 1 < i and not p(b[i]) do
        i = i - 1
    end
    while 1 < i and p(b[i-1]) do
        i = i - 1
    end
    return i
end

function M:paste()
    tablex.insertvalues(self.buffer, self.cursor, self.yank)
    self:move(self.cursor + #self.yank)
end

function M:tab(dir, mklist)
    local cur = self.cursor
    local i

    if self.state == 'tab' then
        local tabix = self.tabix
        local tablist = self.tablist
        self.tabix = (tabix + dir - 1) % #tablist + 1
        i = cur - #tablist[tabix]
    else
        i = self:search_prev_word(function(c) return c ~= 32 end)
        local prefix = utf8.char(table.unpack(self.buffer, 1, i - 1))
        local seed = utf8.char(table.unpack(self.buffer, i, cur - 1))
        self.tabix, self.tablist = mklist(prefix, seed)
        if self.tablist == nil then
            return
        end
        for ix, str in ipairs(self.tablist) do
            self.tablist[ix] = table.pack(utf8.codepoint(str, 1, -1))
        end
    end

    local buffer = self.buffer
    tablex.removevalues(buffer, i, cur - 1)
    local new = self.tablist[self.tabix]
    tablex.insertvalues(buffer, i, new)
    self:move(i + #new, 'tab')
end

return M
