local tablex = require 'pl.tablex'

local M = {
    title = 'session',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    green()
    addstr('          -= IRC session =-\n')
    normal()
    addstr '\n'

    if not irc_state then return end

    addstr 'Phase:    '
    bold()
    addstr(irc_state.phase)
    normal()
    addstr '\n'

    addstr 'Caps:    '
    bold()
    for k, v in tablex.sort(irc_state.caps_available) do
        if irc_state.caps_enabled[k] then
            green()
        else
            red()
        end
        addstr ' ' addstr(k)
        if v ~= true then
            addstr '='
            addstr(v)
        end
    end
    normal()
    addstr '\n'

    addstr 'Channels:'
    bold()
    for _, v in tablex.sort(irc_state.channels) do
        addstr ' ' addstr(v.name)
    end
    normal()
    addstr '\n'

    addstr 'Monitor: '
    for _, v in tablex.sort(irc_state.monitor) do
        if v.online then
            green()
        else
            red()
        end
        addstr ' ' addstr(v.nick)
    end
    normal()
    addstr '\n'

    draw_global_load()
end

return M
