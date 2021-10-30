local execute = {}

function execute.filter()
    filter = editor.rendered
    if filter == '' then
        filter = nil
    end
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
        if command ~= '' then
            status_message = 'unknown command'
        end
        editor:reset()
        input_mode = nil
    end
end

local function ctrl(x)
    return 0x1f & string.byte(x)
end

local function meta(x)
    return -string.byte(x)
end

-- Global keyboard mapping - can be overriden by views
local M = {
    --[[Esc]][0x1b] = function()
        reset_filter()
        status_message = nil
        editor:reset()
        input_mode = nil
        scroll = 0
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

    [ctrl 'L'] = ncurses.clear,
    [ctrl 'N'] = next_view,
    [ctrl 'P'] = prev_view,

    [0x7f] = function() if input_mode then editor:backspace() end end, -- Del
    [-ncurses.KEY_BACKSPACE] = function() if input_mode then editor:backspace() end end,
    [ctrl 'M'] = function() if input_mode then execute[input_mode]() end end, -- Enter
    [ctrl 'U'] = function() if input_mode then editor:kill_to_beg() end end,
    [ctrl 'K'] = function() if input_mode then editor:kill_to_end() end end,
    [ctrl 'A'] = function() if input_mode then editor:move_to_beg() end end,
    [ctrl 'E'] = function() if input_mode then editor:move_to_end() end end,
    [ctrl 'W'] = function() if input_mode then editor:kill_region() end end,
    [ctrl 'B'] = function() if input_mode then editor:left() end end,
    [ctrl 'F'] = function() if input_mode then editor:right() end end,
    [ctrl 'Y'] = function() if input_mode then editor:paste() end end,
    [ctrl 'T'] = function() if input_mode then editor:swap() end end,
    [meta 'f'] = function() if input_mode then editor:next_word() end end,
    [meta 'b'] = function() if input_mode then editor:prev_word() end end,
    [-ncurses.KEY_LEFT] = function() if input_mode then editor:left() end end,
    [-ncurses.KEY_RIGHT] = function() if input_mode then editor:right() end end,
    [-ncurses.KEY_HOME] = function() if input_mode then editor:move_to_beg() end end,
    [-ncurses.KEY_END] = function() if input_mode then editor:move_to_end() end end,

    [ctrl('C')] = function() snowcone.raise(2) end,
    [ctrl('Z')] = function() snowcone.raise(18) end,

    [ctrl('S')] = function()
        editor:reset()
        input_mode = 'filter'
    end,
    [string.byte('/')] = function()
        editor:reset()
        input_mode = 'command'
    end,
}

return M
