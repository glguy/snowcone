-- Loaded plugins, their errors and the views they added. Click an error
-- marked ▸ for its traceback.

local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local log     <const> = require 'hub.runtime.log'
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
                win:waddstr ' '
                local first = scrub(tostring(entry.error):match '^[^\n]*')
                local data = log.error_data('plugin ' .. entry.name, entry.error)
                if data then
                    -- the rest of it in the detail pane
                    ctx.add_button(win, first, function()
                        control.open_detail('error', nil, data)
                    end, true)
                    draw.yellow(win)
                    win:waddstr ' ▸'
                else
                    win:waddstr(first)
                end
                draw.normal(win)
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
