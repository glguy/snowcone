local tablex = require 'pl.tablex'

local M = {
    title = 'bouncer',
    keypress = function() end,
    draw_status = function() end,
}

function M:render(win)
    green(win)
    win:waddstr('          -= bouncer-networks =-\n')
    normal(win)

    local networks = irc_state.bouncer_networks
    if nil == networks then
        win:waddstr 'no bouncer networks'
    else
        for netid, attrs in tablex.sort(networks) do
            green(win)
            win:waddstr(string.format('%5s', netid))
            normal(win)
            local e
            for key, val in tablex.sort(attrs) do
                if key == 'error' then
                    e = val
                else
                    blue(win)
                    win:waddstr(string.format(' %s: ', key))
                    normal(win)
                    win:waddstr(val)
                end
            end
            win:waddstr '\n'
            if nil ~= e then
                blue(win)
                win:waddstr('      error: ')
                normal(win)
                win:waddstr(e)
                win:waddstr '\n'
            end
        end
    end
end

return M
