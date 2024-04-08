local scrub = require 'utils.scrub'
local tablex = require 'pl.tablex'

local M = {
    title = 'session',
    keypress = function() end,
    draw_status = function() end,
}

function M:render(win_side, win_main)

    local function label(txt)
        local y, _x = ncurses.getyx(win_main)
        ncurses.move(y, 0, win_side)
        win_side:addstr(string.format('%24s:', txt))
    end

    ncurses.move(0,0, win_main)

    green(win_main)
    win_main:addstr('          -= IRC session =-\n')
    normal(win_main)
    win_main:addstr '\n'

    if not irc_state then return end

    label 'Phase'
    bold(win_main)
    win_main:addstr(irc_state.phase)
    normal(win_main)
    win_main:addstr '\n'

    if irc_state.nick then
        label('Nick')
        bold(win_main)
        win_main:addstr(scrub(irc_state.nick), '\n')
        normal(win_main)
    end

    label 'Mode'
    for k, _ in tablex.sort(irc_state.mode) do
        win_main:addstr(scrub(k))
    end
    win_main:addstr('\n')

    label 'Caps'
    bold(win_main)
    for k, v in tablex.sort(irc_state.caps_available) do
        if irc_state.caps_enabled[k] then
            green(win_main)
        else
            red(win_main)
        end
        win_main:addstr(scrub(k))
        if v ~= true then
            win_main:addstr '='
            win_main:addstr(scrub(v))
        end
        win_main:addstr(' ')
    end
    normal(win_main)
    win_main:addstr '\n'

    label 'Channels'
    bold(win_main)
    for _, v in tablex.sort(irc_state.channels) do
        win_main:addstr(scrub(v.name), ' ')
    end
    normal(win_main)
    win_main:addstr('\n')

    if irc_state.monitor then
        label 'Monitor'
        for k, v in tablex.sort(irc_state.monitor) do
            if v.user then
                green(win_main)
                win_main:addstr(' ', scrub(v.user.nick))
            else
                red(win_main)
                win_main:addstr(' ', scrub(k:lower()))
            end
        end
        normal(win_main)
        win_main:addstr '\n'
    end
end

return M
