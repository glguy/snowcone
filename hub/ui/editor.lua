-- Line editor with history and kill ring.
--
-- The editor is a plain record in HUB.state.ui.input, so the line being
-- typed and the history survive a reload.

local tablex <const> = require 'pl.tablex'

local M = {}

local render

---@return table a new, empty editor record
function M.new()
    local self = {}
    self.buffer = {}        -- Array[Code]
    self.history = {}       -- Array[Array[Code]]
    self.cursor = 1         -- Index into buffer
    self.retrospect = nil   -- Index into history
    self.stash = nil        -- Original buffer when retrospect ~= nil
    self.yank = {}          -- Array[Code]
    self.state = nil        -- edit(nil), kill, tab
    self.tablist = nil
    self.tabix = nil
    render(self)
    return self
end

function M.content(self)
    return utf8.char(table.unpack(self.buffer))
end

function M.size(self)
    return #self.buffer
end

function M.move(self, x, state)
    self.cursor = x
    self.state = state
    render(self)
end

function render(self)
    self.before_cursor = utf8.char(table.unpack(self.buffer, 1, self.cursor - 1))
    self.at_cursor = utf8.char(table.unpack(self.buffer, self.cursor))
end

function M.reset(self)
    self.buffer = {}
    self.retrospect = nil
    self.stash = nil
    M.move(self, 1)
end

-- Two lines hold the same characters in the same order. Order matters:
-- otherwise an anagram of the last line would be dropped from history.
local function same_line(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

function M.confirm(self)
    local n = #self.history
    if n == 0 or not same_line(self.history[n], self.buffer) then
        self.history[n+1] = self.buffer
    end
    M.reset(self)
end

function M.older_history(self)
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
        M.move_to_end(self)
    elseif r == nil and h[1] ~= nil then
        r = #h
        self.stash = self.buffer
        self.buffer = tablex.copy(h[r])
        self.retrospect = r
        M.move_to_end(self)
    end
end

function M.newer_history(self)
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

    M.move_to_end(self)
end

function M.is_empty(self)
    return not self.buffer[1]
end

function M.backspace(self)
    local i = self.cursor
    if 1 < i then
        table.remove(self.buffer, i - 1)
        M.move(self, i - 1)
    end
end

function M.delete(self)
    table.remove(self.buffer, self.cursor)
    self.state = nil
    render(self)
end

function M.add_yank_left(self, lo, hi)
    local t = tablex.sub(self.buffer, lo, hi)
    if self.state == 'kill' then
        tablex.insertvalues(self.yank, 1, t)
    else
        self.yank = t
        self.state = 'kill'
    end
end

function M.kill_to_beg(self)
    M.add_yank_left(self, 1, self.cursor - 1)
    self.buffer = tablex.sub(self.buffer, self.cursor, -1)
    M.move(self, 1, 'kill')
end

function M.kill_to_end(self)
    if self.state == 'kill' then
        table.move(self.buffer, self.cursor, #self.buffer, #self.yank + 1, self.yank)
    else
        self.yank = tablex.sub(self.buffer, self.cursor, -1)
        self.state = 'kill'
    end
    tablex.removevalues(self.buffer, self.cursor, - 1)
    render(self)
end

function M.kill_prev_word(self)
    local i = M.search_prev_word(self)
    local j = self.cursor - 1

    M.add_yank_left(self, i, j)
    tablex.removevalues(self.buffer, i, j)
    M.move(self, i, 'kill')
end


function M.kill_next_word(self)
    local i = self.cursor
    local j = M.search_next_word(self) - 1

    -- extract that region
    local region = tablex.sub(self.buffer, i, j)
    tablex.removevalues(self.buffer, i, j)

    if self.state == 'kill' then
        tablex.insertvalues(self.yank, #self.yank + 1, region)
    else
        self.yank = region
        self.state = 'kill'
    end

    M.move(self, i, 'kill')
end

function M.add(self, code)
    table.insert(self.buffer, self.cursor, code)
    M.move(self, self.cursor + 1)
end

function M.swap(self)
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
        M.move(self, i)
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

-- Look for sequences of 'x' and then hex digits just before the cursor.
-- Line breaks are allowed: the editor also takes Lua code (/eval). NUL is
-- not, since text goes through C strings.
function M.hexinput(self)
    local b = self.buffer
    local last = self.cursor - 1

    -- Support ^A style control characters
    if 1 < last
    and b[last - 1] == 0x5e -- '^'
    then
        local c = b[last]
        if 0x41 <= c and c <= 0x5f -- ^A-^Z ^[ ^\ ^] ^^ ^_
        then
            b[last - 1] = c - 0x40 -- replaces the '^' with control character
            table.remove(b, last)
            M.move(self, last)
            return
        end
    end

    -- Support x0123 style unicode values
    -- Find the value of i such than i points at: x[0-9a-fA-F]+
    if not hexdigits[b[last]] then return end -- no digits before the cursor
    local first = last
    while 1 < first do
        if b[first - 1] == 120 then -- check for 'x'

            -- Compute new value
            local acc = 0
            for j = first, last do
                acc = 16 * acc + hexdigits[b[j]]
            end

            -- ensure value is valid for the input buffer
            if acc == 0 or acc > 0x10ffff then return end

            -- replace escape sequence with value
            tablex.removevalues(b, first, last)
            b[first - 1] = acc -- replaces the 'x'

            M.move(self, first)
            return -- done
        elseif hexdigits[b[first - 1]] then
            first = first - 1
        else
            return -- bad sequence
        end
    end
end

function M.move_to_beg(self)
    M.move(self, 1)
end

function M.move_to_end(self)
    M.move(self, #self.buffer + 1)
end

function M.move_left(self)
    if self.cursor > 1 then
        M.move(self, self.cursor - 1)
    end
end

function M.move_right(self)
    if self.cursor <= #self.buffer then
        M.move(self, self.cursor + 1)
    end
end

function M.move_next_word(self)
    M.move(self, M.search_next_word(self))
end

function M.move_prev_word(self)
    M.move(self, M.search_prev_word(self))
end

function M.search_next_word(self)
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

function M.search_prev_word(self, p)
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

function M.paste(self)
    tablex.insertvalues(self.buffer, self.cursor, self.yank)
    M.move(self, self.cursor + #self.yank)
end

function M.tab(self, dir, mklist)
    local cur = self.cursor
    local i

    if self.state == 'tab' then
        local tabix = self.tabix
        local tablist = self.tablist
        self.tabix = (tabix + dir - 1) % #tablist + 1
        i = cur - #tablist[tabix]
    else
        i = M.search_prev_word(self, function(c) return c ~= 32 end)
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
    M.move(self, i + #new, 'tab')
end

return M
