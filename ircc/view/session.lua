local scrub = require 'utils.scrub'
local tablex = require 'pl.tablex'

local M = {
    title = 'session',
    keypress = function() end,
    draw_status = function() end,
}

function M:render(win)

    local function label(txt)
        win:waddstr(string.format('%14s: ', txt))
    end

    win:wmove(0, 0)
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

    if irc_state.snomask then
        label 'Snomask'
        win:waddstr(scrub(irc_state.snomask), '\n')
    end

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
        local text = scrub(v.name)
        local _, x = ncurses.getyx(win)
        if x + #text > tty_width then
            win:waddstr('\n                ')
        end
        add_button(win, text, function()
            set_talk_target(snowcone.irccase(v.name))
            set_view 'buffer'
        end, true)
        win:waddstr(' ')
    end
    normal(win)
    win:waddstr('\n')

    if irc_state.monitor then
        label 'Monitor'
        for k, v in tablex.sort(irc_state.monitor) do
            if v.user then
                green(win)
                win:waddstr(scrub(v.user.nick), ' ')
            else
                red(win)
                win:waddstr(scrub(k:lower()), ' ')
            end
        end
        normal(win)
        win:waddstr '\n'
    end

    label 'Tasks'
    bold(win)
    for k, _ in pairs(irc_state.tasks) do
        win:waddstr(k.name, ' ')
    end
    bold_(win)
    win:waddstr '\n'
end

return M
