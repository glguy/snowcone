local scrub = require 'utils.scrub'
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

    addstr '   Phase: '
    bold()
    addstr(irc_state.phase)
    normal()
    addstr '\n'

    addstr '    Mode: '
    for k, _ in tablex.sort(irc_state.mode) do
        addstr(scrub(k))
    end
    addstr '\n'

    addstr '    Caps:'
    bold()
    for k, v in tablex.sort(irc_state.caps_available) do
        if irc_state.caps_enabled[k] then
            green()
        else
            red()
        end
        addstr ' ' addstr(scrub(k))
        if v ~= true then
            addstr '='
            addstr(scrub(v))
        end
    end
    normal()
    addstr '\n'

    addstr 'Channels:'
    bold()
    for _, v in tablex.sort(irc_state.channels) do
        addstr ' ' addstr(scrub(v.name))
    end
    normal()
    addstr '\n'

    if irc_state.monitor then
        addstr ' Monitor:'
        for k, v in tablex.sort(irc_state.monitor) do
            if v.user then
                green()
                addstr ' ' addstr(scrub(v.user.nick))
            else
                red()
                addstr ' ' addstr(scrub(k:lower()))
            end
        end
        normal()
        addstr '\n'
    end
end

return M
