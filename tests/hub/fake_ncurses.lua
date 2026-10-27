-- A stand-in for the ncurses module, so the UI can load and draw without a
-- terminal. Upper-case names (KEY_, COLOR_, WA_ constants) are numbers;
-- everything else is a function that does nothing. Windows accept any
-- method, track the cursor through wmove and waddstr, and keep their text.
--
--   local fake = dofile 'fake_ncurses.lua'
--   fake.install()    -- sets the ncurses, tty_width and tty_height globals

local M = {}

local constants = {}
local next_constant = 1000

local function constant(name)
    local v = constants[name]
    if not v then
        next_constant = next_constant + 1
        v = next_constant
        constants[name] = v
    end
    return v
end

-- Every window made, in order
M.windows = {}

-- A window of h rows and w columns (unbounded when not given). Text wraps
-- at the right edge and stops at the bottom, as with scrolling off; each
-- row's text is kept for M.row.
local function new_window(kind, h, w)
    local win = {kind = kind, y = 0, x = 0, h = h or math.huge, w = w or math.huge, text = {}}
    table.insert(M.windows, win)
    local function put(self, c)
        if self.x >= self.w then self.y, self.x = self.y + 1, 0 end
        if self.y >= self.h then self.y, self.x = self.h - 1, self.w - 1 return end
        local row = self.text[self.y] or {}
        self.text[self.y] = row
        row[self.x + 1] = c
        self.x = self.x + 1
    end
    return setmetatable(win, {__index = function(_, name)
        if name == 'wmove' then
            return function(self, y, x) self.y, self.x = y, x end
        elseif name == 'waddstr' then
            return function(self, ...)
                for i = 1, select('#', ...) do
                    for _, c in utf8.codes(tostring((select(i, ...)))) do
                        if c == 10 then
                            if self.y + 1 < self.h then self.y, self.x = self.y + 1, 0 end
                        else
                            put(self, utf8.char(c))
                        end
                    end
                end
            end
        elseif name == 'werase' then
            return function(self) self.y, self.x, self.text = 0, 0, {} end
        elseif name == 'wresize' then
            return function(self, rows, cols) self.h, self.w = rows, cols end
        elseif name == 'pnoutrefresh' then
            return function(self, top) self.top = top end
        end
        return function() end
    end})
end

--- The text of row y of a window, with gaps as spaces.
function M.row(win, y)
    local row = win.text[y] or {}
    local last = 0
    for x in pairs(row) do last = math.max(last, x) end
    local out = {}
    for x = 1, last do out[x] = row[x] or ' ' end
    return table.concat(out)
end

M.ncurses = setmetatable({}, {__index = function(_, name)
    if name:match '^%u' then
        return constant(name)
    elseif name == 'newwin' or name == 'newpad' then
        return function(h, w) return new_window(name, h, w) end
    elseif name == 'getyx' then
        return function(win)
            if type(win) == 'table' then return win.y, win.x end
            return 0, 0
        end
    elseif name == 'getmaxyx' then
        return function(win)
            if type(win) == 'table' then return win.h, win.w end
            return rawget(_G, 'tty_height'), rawget(_G, 'tty_width')
        end
    end
    return function() end
end})

function M.install(width, height)
    rawset(_G, 'ncurses', M.ncurses)
    rawset(_G, 'tty_width', width or 150)
    rawset(_G, 'tty_height', height or 40)
end

return M
