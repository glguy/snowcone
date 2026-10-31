-- Line editor with history, undo and a kill ring.
--
-- The editor is a plain record in HUB.state.ui.input, so the line being
-- typed and the history survive a reload.

local OrderedMap    <const> = require 'hub.lib.OrderedMap'
local tablex        <const> = require 'pl.tablex'

local M = {}

-- Lines kept in history, changes kept for undo and kills kept for
-- yanking; the oldest are dropped first
local history_limit <const> = 1000
local undo_limit    <const> = 100
local kill_limit    <const> = 60

local render

---@return hub.Editor # a new, empty editor record
function M.new()
    ---@class hub.Editor
    ---@field buffer integer[] code points of the line
    ---@field cursor integer index into buffer
    ---@field history hub.OrderedMap lines entered, numbered from 1
    ---@field edits table<integer, integer[]> edits to recalled lines, by
    --- number; the line being typed is number last(history) + 1. Cleared
    --- with the line.
    ---@field undo hub.OrderedMap {buffer, cursor} before each change
    ---@field kills hub.OrderedMap killed text, as code points
    ---@field before_cursor string rendered text, for the status bar
    ---@field at_cursor string
    ---@field at integer|nil the number of the history line shown, while recalling
    ---@field state 'insert'|'kill'|'tab'|'yank'|nil the last change; nil for an edit
    ---@field tablist any[]|nil completions, when state is tab: strings from
    --- mklist, turned into code point arrays in place
    ---@field tabix integer|nil the completion shown
    ---@field yanked {at: integer, n: integer, k: integer}|nil the text the last
    --- yank put in, and its number in kills, when state is yank
    local self = {}
    self.buffer = {}
    self.history = OrderedMap.new(history_limit)
    self.edits = {}
    self.cursor = 1
    self.undo = OrderedMap.new(undo_limit)
    self.kills = OrderedMap.new(kill_limit)
    render(self)
    return self
end

-- Remember the line before a change. A change that continues the last
-- one, when the state is already kind, joins it: a run of typing undoes
-- at once, and so does a run of completions.
---@param self hub.Editor
local function save(self, kind)
    if kind and self.state == kind then return end
    OrderedMap.insert(self.undo, nil, {buffer = tablex.copy(self.buffer), cursor = self.cursor})
end

---@param self hub.Editor
function M.undo(self)
    local last = OrderedMap.pop(self.undo)
    if last then
        self.buffer = last.buffer
        M.move(self, last.cursor)
    end
end

---@param self hub.Editor
function M.content(self)
    return utf8.char(table.unpack(self.buffer))
end

---@param self hub.Editor
function M.size(self)
    return #self.buffer
end

---@param self hub.Editor
function M.move(self, x, state)
    self.cursor = x
    self.state = state
    render(self)
end

---@param self hub.Editor
function render(self)
    self.before_cursor = utf8.char(table.unpack(self.buffer, 1, self.cursor - 1))
    self.at_cursor = utf8.char(table.unpack(self.buffer, self.cursor))
end

---@param self hub.Editor
function M.reset(self)
    self.buffer = {}
    OrderedMap.reset(self.undo)
    self.edits = {}
    self.at = nil
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

---@param self hub.Editor
function M.confirm(self)
    local history = self.history
    local newest = OrderedMap.get(history, OrderedMap.last(history))
    if not (newest and same_line(newest, self.buffer)) then
        OrderedMap.insert(history, nil, self.buffer)
    end
    M.reset(self)
end

-- Show line k: a line from history, or last(history) + 1 for the line being
-- typed. What was shown is kept in edits, so coming back to it finds it
-- as it was left; history itself never changes.
---@param self hub.Editor
local function go_to(self, k)
    local typing = OrderedMap.last(self.history) + 1
    local here = self.at or typing
    local line = OrderedMap.get(self.history, k)
    if k == here or not (line or k == typing) then return end
    self.edits[here] = self.buffer
    self.buffer = self.edits[k] or tablex.copy(line or {})
    self.at = line and k or nil
    OrderedMap.reset(self.undo)
    M.move_to_end(self)
end

---@param self hub.Editor
function M.older_history(self)
    go_to(self, (self.at or OrderedMap.last(self.history) + 1) - 1)
end

---@param self hub.Editor
function M.newer_history(self)
    if self.at then go_to(self, self.at + 1) end
end

---@param self hub.Editor
function M.oldest_history(self)
    go_to(self, OrderedMap.first(self.history))
end

-- back to the line being typed before recalling
---@param self hub.Editor
function M.newest_history(self)
    go_to(self, OrderedMap.last(self.history) + 1)
end

---@param self hub.Editor
function M.is_empty(self)
    return not self.buffer[1]
end

--- The line shown holds something typed: the line being typed, unless
--- empty, or a recalled line changed from its history.
---@param self hub.Editor
function M.typed(self)
    if not self.at then return self.buffer[1] ~= nil end
    local line = OrderedMap.get(self.history, self.at)
    return not (line and same_line(line, self.buffer))
end

---@param self hub.Editor
function M.backspace(self)
    local i = self.cursor
    if 1 < i then
        save(self)
        table.remove(self.buffer, i - 1)
        M.move(self, i - 1)
    end
end

---@param self hub.Editor
function M.delete(self)
    if self.cursor <= #self.buffer then
        save(self)
        table.remove(self.buffer, self.cursor)
    end
    self.state = nil
    render(self)
end

-- Cut buffer[lo..hi] into the kill ring. Consecutive kills add to the
-- newest kill, before it when killing backward. Killing nothing leaves
-- the ring alone.
---@param self hub.Editor
local function kill(self, lo, hi, backward)
    if lo <= hi then
        save(self)
        local t = tablex.sub(self.buffer, lo, hi)
        tablex.removevalues(self.buffer, lo, hi)
        local kills = self.kills
        local newest = OrderedMap.get(kills, OrderedMap.last(kills))
        if self.state == 'kill' and newest then
            tablex.insertvalues(newest, backward and 1 or #newest + 1, t)
        else
            OrderedMap.insert(kills, nil, t)
        end
    end
    M.move(self, lo, 'kill')
end

---@param self hub.Editor
function M.kill_to_beg(self)
    kill(self, 1, self.cursor - 1, true)
end

---@param self hub.Editor
function M.kill_to_end(self)
    kill(self, self.cursor, #self.buffer, false)
end

-- Words end at spaces rather than punctuation, as readline's C-w
local function not_space(c)
    return c ~= 0x20 and c ~= 0x09 and c ~= 0x0a
end

---@param self hub.Editor
function M.kill_prev_word(self, p)
    kill(self, M.search_prev_word(self, p), self.cursor - 1, true)
end

---@param self hub.Editor
function M.kill_prev_spaced_word(self)
    M.kill_prev_word(self, not_space)
end

---@param self hub.Editor
function M.kill_next_word(self)
    kill(self, self.cursor, M.search_next_word(self) - 1, false)
end

---@param self hub.Editor
function M.add(self, code)
    save(self, 'insert')
    table.insert(self.buffer, self.cursor, code)
    M.move(self, self.cursor + 1, 'insert')
end

---@param self hub.Editor
function M.swap(self)
    local n = #self.buffer
    local i = self.cursor
    if n > 1 then
        if i == 1 then
            i = 3
        elseif i <= n then
            i = i + 1
        end
        save(self)
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
---@param self hub.Editor
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
            save(self)
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
            -- the value must be a code point other than NUL
            local acc = 0
            for j = first, last do
                acc = 16 * acc + hexdigits[b[j]]
                if acc > 0x10ffff then return end
            end
            if acc == 0 then return end

            -- replace escape sequence with value
            save(self)
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

---@param self hub.Editor
function M.move_to_beg(self)
    M.move(self, 1)
end

---@param self hub.Editor
function M.move_to_end(self)
    M.move(self, #self.buffer + 1)
end

---@param self hub.Editor
function M.move_left(self)
    if self.cursor > 1 then
        M.move(self, self.cursor - 1)
    end
end

---@param self hub.Editor
function M.move_right(self)
    if self.cursor <= #self.buffer then
        M.move(self, self.cursor + 1)
    end
end

---@param self hub.Editor
function M.move_next_word(self)
    M.move(self, M.search_next_word(self))
end

---@param self hub.Editor
function M.move_prev_word(self)
    M.move(self, M.search_prev_word(self))
end

-- Letters and digits, counting every non-ASCII character as a letter
local function is_word(c)
    return c >= 0x80 or snowcone.isalnum(c)
end

-- The end of the word at or after a position (default: the cursor)
---@param self hub.Editor
function M.search_next_word(self, at)
    local p = is_word
    local i = at or self.cursor
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

-- The start of the word before a position (default: the cursor)
---@param self hub.Editor
function M.search_prev_word(self, p, at)
    p = p or is_word
    local i = at or self.cursor
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

-- Swap the words before and after the cursor, or at the end of the line
-- the last two, leaving the cursor after them
---@param self hub.Editor
function M.swap_words(self)
    local s2 = M.search_prev_word(self, nil, M.search_next_word(self))
    local e2 = M.search_next_word(self, s2)
    local s1 = M.search_prev_word(self, nil, s2)
    local e1 = M.search_next_word(self, s1)
    if s2 < e1 then return end -- fewer than two words

    save(self)
    local b = self.buffer
    local t = tablex.sub(b, 1, s1 - 1)
    tablex.insertvalues(t, tablex.sub(b, s2, e2 - 1))
    tablex.insertvalues(t, tablex.sub(b, e1, s2 - 1))
    tablex.insertvalues(t, tablex.sub(b, s1, e1 - 1))
    tablex.insertvalues(t, tablex.sub(b, e2, -1))
    self.buffer = t
    M.move(self, e2)
end

-- Case changes are ASCII only
local function upcase(c)
    if 0x61 <= c and c <= 0x7a then return c - 0x20 end
    return c
end

local function downcase(c)
    if 0x41 <= c and c <= 0x5a then return c + 0x20 end
    return c
end

-- Change the letters from the cursor to the end of the word and move
-- there. f gets each word character and whether it is the first.
---@param self hub.Editor
local function change_word(self, f)
    local b = self.buffer
    local j = M.search_next_word(self)
    local first, saved = true, false
    for i = self.cursor, j - 1 do
        if is_word(b[i]) then
            local c = f(b[i], first)
            first = false
            if c ~= b[i] then
                if not saved then
                    save(self)
                    saved = true
                end
                b[i] = c
            end
        end
    end
    M.move(self, j)
end

---@param self hub.Editor
function M.upcase_word(self) change_word(self, upcase) end
---@param self hub.Editor
function M.downcase_word(self) change_word(self, downcase) end
---@param self hub.Editor
function M.capitalize_word(self)
    change_word(self, function(c, first)
        if first then return upcase(c) else return downcase(c) end
    end)
end

-- Insert kill k at the cursor, remembering where for paste_older
---@param self hub.Editor
local function yank(self, k)
    local t = OrderedMap.get(self.kills, k)
    local at = self.cursor
    tablex.insertvalues(self.buffer, at, t)
    self.yanked = {at = at, n = #t, k = k}
    M.move(self, at + #t, 'yank')
end

---@param self hub.Editor
function M.paste(self)
    if OrderedMap.size(self.kills) > 0 then
        save(self)
        yank(self, OrderedMap.last(self.kills))
    end
end

-- Right after a paste, replace what it put in with the next older kill,
-- going round to the newest after the oldest
---@param self hub.Editor
function M.paste_older(self)
    local y = self.yanked
    local kills = self.kills
    if self.state ~= 'yank' or OrderedMap.size(kills) < 2 then return end
    ---@cast y -nil yank sets yanked with the state
    save(self)
    tablex.removevalues(self.buffer, y.at, y.at + y.n - 1)
    self.cursor = y.at
    local k = y.k - 1
    if k < OrderedMap.first(kills) then k = OrderedMap.last(kills) end
    yank(self, k)
end

---@param self hub.Editor
function M.tab(self, dir, mklist)
    local cur = self.cursor
    local i

    if self.state == 'tab' then
        local tabix = self.tabix
        local tablist = self.tablist
        ---@cast tabix -nil
        ---@cast tablist -nil a completion sets both with the state
        self.tabix = (tabix + dir - 1) % #tablist + 1
        i = cur - #tablist[tabix]
    else
        -- the spaceless run before the cursor: empty just after a space
        i = cur
        while 1 < i and self.buffer[i - 1] ~= 32 do
            i = i - 1
        end
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

    save(self, 'tab')
    local buffer = self.buffer
    tablex.removevalues(buffer, i, cur - 1)
    local new = self.tablist[self.tabix]
    tablex.insertvalues(buffer, i, new)
    M.move(self, i + #new, 'tab')
end

return M
