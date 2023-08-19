-- Global keyboard mapping - can be overriden by views
local M = {
    --[[Esc]][0x1b] = function()
        reset_filter()
        status_message = nil
        editor:reset()
        input_mode = nil
        scroll = 0
    end,

    [-ncurses.KEY_RESUME] = function()
        terminal_focus = true
        notification_ok = nil -- don't notify while focused
    end,

    [-ncurses.KEY_EXIT] = function()
        terminal_focus = nil
        notification_ok = true -- allow a notification
    end,

    [ctrl 'L'] = function() ncurses.clear() draw() end,
    [ctrl 'N'] = next_view,
    [ctrl 'P'] = prev_view,

    [ctrl 'C'] = function() snowcone.raise(snowcone.SIGINT) end,
    [ctrl 'Z'] = function() snowcone.raise(snowcone.SIGTSTP) end,

    [ctrl 'S'] = function()
        editor:reset()
        input_mode = 'filter'
    end,
    [string.byte('/')] = function()
        editor:reset()
        input_mode = 'command'
    end,
}

for i, v in ipairs(main_views) do
    M[-(ncurses.KEY_F1 - 1 + i)] = function() view = v end
end

return M
