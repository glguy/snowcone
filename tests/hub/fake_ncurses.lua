-- A stand-in for the ncurses module, so the UI can load and draw without a
-- terminal. It has the real module's names (tests-terminal checks that they
-- match) and raises an error for any other. Constants are distinct numbers;
-- functions do nothing unless defined below. Windows track the cursor
-- through wmove and waddstr, and keep their text.
--
--   local fake = dofile 'fake_ncurses.lua'
--   fake.install()    -- sets the ncurses, tty_width and tty_height globals

local M = {}

-- The real module's names
M.functions = {
    'addstr', 'attrget', 'attroff', 'attron', 'attrset', 'beep', 'clear',
    'colorset', 'cursset', 'doupdate', 'erase', 'flash', 'getmaxyx', 'getyx',
    'move', 'mvaddstr', 'newpad', 'newwin', 'noutrefresh', 'refresh',
}
M.methods = {
    'delwin', 'pnoutrefresh', 'prefresh', 'waddstr', 'wclear', 'werase',
    'wmove', 'wresize',
}
M.constants = {
    'COLOR_BLACK', 'COLOR_BLUE', 'COLOR_CYAN', 'COLOR_DEFAULT', 'COLOR_GREEN',
    'COLOR_MAGENTA', 'COLOR_RED', 'COLOR_WHITE', 'COLOR_YELLOW',
    'KEY_BACKSPACE', 'KEY_BTAB', 'KEY_DC', 'KEY_DOWN', 'KEY_END', 'KEY_EXIT',
    'KEY_F1', 'KEY_F10', 'KEY_F11', 'KEY_F12', 'KEY_F2', 'KEY_F3', 'KEY_F4',
    'KEY_F5', 'KEY_F6', 'KEY_F7', 'KEY_F8', 'KEY_F9', 'KEY_HOME', 'KEY_LEFT',
    'KEY_NPAGE', 'KEY_PPAGE', 'KEY_RESUME', 'KEY_RIGHT', 'KEY_UP',
    'WA_ALTCHARSET', 'WA_BLINK', 'WA_BOLD', 'WA_DIM', 'WA_ITALIC', 'WA_NORMAL',
    'WA_REVERSE', 'WA_STANDOUT', 'WA_UNDERLINE',
}

local function set(list)
    local result = {}
    for _, name in ipairs(list) do result[name] = true end
    return result
end
local is_function, is_method, is_constant = set(M.functions), set(M.methods), set(M.constants)

local constant_values = {}
for i, name in ipairs(M.constants) do constant_values[name] = 1000 + i end

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
        elseif is_method[name] then
            return function() end
        end
        error('fake ncurses: windows have no method ' .. tostring(name), 2)
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
    if is_constant[name] then
        return constant_values[name]
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
    elseif is_function[name] then
        return function() end
    end
    error('fake ncurses: no ' .. tostring(name), 2)
end})

function M.install(width, height)
    rawset(_G, 'ncurses', M.ncurses)
    rawset(_G, 'tty_width', width or 150)
    rawset(_G, 'tty_height', height or 40)
end

return M
