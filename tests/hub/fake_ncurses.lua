-- A stand-in for the ncurses module, so the UI can load and draw without a
-- terminal. Upper-case names (KEY_, COLOR_, WA_ constants) are numbers;
-- everything else is a function that does nothing. Windows accept any
-- method and track the cursor through wmove and waddstr.
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

local function new_window()
    local win = {y = 0, x = 0}
    return setmetatable(win, {__index = function(_, name)
        if name == 'wmove' then
            return function(self, y, x) self.y, self.x = y, x end
        elseif name == 'waddstr' then
            return function(self, ...)
                for i = 1, select('#', ...) do
                    local s = select(i, ...)
                    for line in tostring(s):gmatch '[^\n]*\n?' do
                        if line:sub(-1) == '\n' then
                            self.y, self.x = self.y + 1, 0
                        else
                            self.x = self.x + (utf8.len(line) or #line)
                        end
                    end
                end
            end
        elseif name == 'werase' then
            return function(self) self.y, self.x = 0, 0 end
        end
        return function() end
    end})
end

M.ncurses = setmetatable({}, {__index = function(_, name)
    if name:match '^%u' then
        return constant(name)
    elseif name == 'newwin' or name == 'newpad' then
        return function() return new_window() end
    elseif name == 'getyx' then
        return function(win)
            if type(win) == 'table' then return win.y, win.x end
            return 0, 0
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
