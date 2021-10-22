local execute = {}

function execute.filter()
    filter = editor.rendered
    editor:reset()
    input_mode = nil
end

local commands = require_ 'handlers.commands'
function execute.command()
    local command, args = string.match(editor.rendered, '^ *(%g*) *(.*)$')
    local impl = commands[command]
    if impl then
        editor:reset()
        input_mode = nil
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
        editor:reset()
        input_mode = nil
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
        editor:reset()
        input_mode = 'command'
    end,

    [ctrl('L')] = function() ncurses.clear() end,
    [ctrl('N')] = function() view = view % #views + 1 end,
    [ctrl('P')] = function() view = (view - 2) % #views + 1 end,

    [0x7f] = function() editor:backspace() end, -- Del
    [-ncurses.KEY_BACKSPACE] = function() editor:backspace() end,
    [ctrl('M')] = function() execute[input_mode]() end, -- Enter
    [ctrl('U')] = function() editor:kill_to_beg() end,
    [ctrl('K')] = function() editor:kill_to_end() end,
    [ctrl('A')] = function() editor:move_to_beg() end,
    [ctrl('E')] = function() editor:move_to_end() end,
    [ctrl('W')] = function() editor:kill_region() end,
    [ctrl('B')] = function() editor:left() end,
    [ctrl('F')] = function() editor:right() end,
    [ctrl('Y')] = function() editor:paste() end,
    [-ncurses.KEY_LEFT] = function() editor:left() end,
    [-ncurses.KEY_RIGHT] = function() editor:right() end,

    [ctrl('C')] = function() snowcone.raise(2) end,
    [ctrl('Z')] = function() snowcone.raise(18) end,

    [ctrl('S')] = function()
        editor:reset()
        input_mode = 'filter'
    end,
}

return M
