-- Loaded plugins and the views they added. A plugin that failed to start
-- says so, and its error is in the status view with every other.

local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local plugins <const> = require 'hub.features.plugins'
local scrub   <const> = require 'hub.lib.scrub'

return {
    id = 'plugins',
    title = 'plugins',
    scope = 'global',

    render = function(ctx, win)
        draw.green(win)
        win:waddstr '          -= plugins =-\n'
        draw.normal(win)

        if #plugins.loaded == 0 then
            win:waddstr 'No plugins: list them in [plugins] modules\n'
            return
        end

        for _, entry in ipairs(plugins.loaded) do
            draw.bold(win)
            win:waddstr(string.format('%-16s', scrub(entry.name)))
            draw.normal(win)
            if entry.error then
                draw.red(win)
                win:waddstr ' failed '
                draw.normal(win)
                ctx.add_button(win, '[status]', function() control.set_view 'status' end)
            else
                for _, id in ipairs(entry.views or {}) do
                    win:waddstr ' '
                    ctx.add_button(win, '[' .. id .. ']', function() control.set_view(id) end)
                end
            end
            win:waddstr '\n'
        end
    end,
}
