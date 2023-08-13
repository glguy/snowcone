local tablex = require 'pl.tablex'

local M = {
    title = 'bouncer',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    green()
    addstr('          -= bouncer-networks =-\n')
    normal()

    local networks = irc_state.bouncer_networks
    if nil == networks then
        addstr 'no bouncer networks'
    else
        for netid, attrs in tablex.sort(networks) do
            green()
            addstr(string.format('%5s', netid))
            normal()
            local e
            for key, val in tablex.sort(attrs) do
                if key == 'error' then
                    e = val
                else
                    blue()
                    addstr(string.format(' %s: ', key))
                    normal()
                    addstr(val)
                end
            end
            addstr '\n'
            if nil ~= e then
                blue()
                addstr('      error: ')
                normal()
                addstr(e)
                addstr '\n'
            end
        end
end
    draw_global_load()
end

return M
