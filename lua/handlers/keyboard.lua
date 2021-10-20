local commands = require_ 'handlers.commands'
local function execute()
    local command, args = string.match(buffer, '^ */(%g*) *(.*)$')
    local impl = commands[command]
    if impl then
        buffer = ''
        status_message = ''

        local success, message = pcall(impl, args)
        if not success then
            status_message = string.match(message, '^%C*')
        end
    else
        status_message = 'unknown command'
    end
end

local function ctrl(x)
    return 0x1f & string.byte(x,1)
end

-- Global keyboard mapping - can be overriden by views
local M = {
    --[[Esc]][0x1b] = function()
        reset_filter()
        status_message = nil
    end,
    [-ncurses.KEY_F1] = function() view = 1 scroll = 0 end,
    [-ncurses.KEY_F2] = function() view = 2 end,
    [-ncurses.KEY_F3] = function() view = 3 scroll = 0 end,
    [-ncurses.KEY_F4] = function() view = 4 end,
    [-ncurses.KEY_F5] = function() view = 5 end,
    [-ncurses.KEY_F6] = function() view = 6 end,
    [-ncurses.KEY_F7] = function() view = 7 end,
    [-ncurses.KEY_F8] = function() view = 8 end,
    [-ncurses.KEY_F9] = function() view = 9 end,
    [-ncurses.KEY_F10] = function() view = 10 end,
    [string.byte('/')] = function()
        if buffer == '' then buffer = '/' end end,

    [ctrl('L')] = function() ncurses.clear() end,
    [ctrl('N')] = function() view = view % #views + 1 end,
    [ctrl('P')] = function() view = (view - 2) % #views + 1 end,

    [0x7f] = function() buffer = string.sub(buffer, 1, #buffer - 1) end, -- Del
    [-ncurses.KEY_BACKSPACE] = function() buffer = string.sub(buffer, 1, #buffer - 1) end,
    [ctrl('M')] = execute, -- Enter
    [ctrl('U')] = function() buffer = '' end,
}

return M
