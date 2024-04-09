local scrub = require 'utils.scrub'
local tablex = require 'pl.tablex'

local keys = {
    [-ncurses.KEY_RIGHT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, math.min(550 - scroll_unit, hscroll + scroll_unit))
    end,
    [-ncurses.KEY_LEFT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, hscroll - scroll_unit)
    end,
}

local M = {
    title = 'session',
    keypress = function(self, key)
        local h = keys[key]
        if h then
            h()
            return true -- consume
        end
    end,
    draw_status = function() end,
}

function M:render(win)

    local function label(txt)
        win:waddstr(string.format('%14s: ', txt))
    end

    ncurses.move(0,0, win)

    green(win)
    win:waddstr('          -= IRC session =-\n')
    normal(win)
    win:waddstr '\n'

    if not irc_state then return end

    label 'Phase'
    bold(win)
    win:waddstr(irc_state.phase)
    normal(win)
    win:waddstr '\n'

    if irc_state.nick then
        label('Nick')
        bold(win)
        win:waddstr(scrub(irc_state.nick), '\n')
        normal(win)
    end

    label 'Mode'
    for k, _ in tablex.sort(irc_state.mode) do
        win:waddstr(scrub(k))
    end
    win:waddstr('\n')

    label 'Caps'
    bold(win)
    for k, v in tablex.sort(irc_state.caps_available) do
        if irc_state.caps_enabled[k] then
            green(win)
        else
            red(win)
        end
        local text = scrub(k)
        if v ~= true then
            text = text .. '=' .. scrub(v)
        end
        local _, x = ncurses.getyx(win)
        if x + #text > tty_width then
            win:waddstr('\n                ', text, ' ')
        else
            win:waddstr(text, ' ')
        end
    end
    normal(win)
    win:waddstr '\n'

    label 'Channels'
    bold(win)
    for _, v in tablex.sort(irc_state.channels) do
        win:waddstr(scrub(v.name), ' ')
    end
    normal(win)
    win:waddstr('\n')

    if irc_state.monitor then
        label 'Monitor'
        for k, v in tablex.sort(irc_state.monitor) do
            if v.user then
                green(win)
                win:waddstr(' ', scrub(v.user.nick))
            else
                red(win)
                win:waddstr(' ', scrub(k:lower()))
            end
        end
        normal(win)
        win:waddstr '\n'
    end
end

return M
