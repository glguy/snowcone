-- Load per name: K-Lines by operator (banload) and filter hits by server
-- (spamload), from the dashboard's view/simple_load.lua.

local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local scrub     <const> = require 'hub.lib.scrub'

local function make_view(id, heading, label, history, tracker_name)
    return {
        id = id,
        title = id,
        scope = 'net',
        feature = 'snotice',

        render = function(ctx, win)
            local S = dashboard.stores(ctx, win)
            if not S then return end
            local tracker = S.trackers[tracker_name]

            local rows = {}
            for name, load in pairs(tracker.detail) do
                table.insert(rows, {name = name, load = load})
            end
            table.sort(rows, function(x, y) return x.name < y.name end)

            local y = math.max(ctx.rows - #rows - 2, 0)
            draw.green(win)
            win:wmove(y, 0)
            win:waddstr(string.format('%16s  1m    5m    15m  %s', heading, history))
            draw.normal(win)
            y = y + 1

            for _, row in ipairs(rows) do
                if y + 1 >= ctx.rows then break end
                win:wmove(y, 0)
                win:waddstr(string.format('%16s ', scrub(row.name)))
                dashboard.draw_load(win, row.load)
                y = y + 1
            end

            if ctx.rows >= 2 then
                draw.blue(win)
                win:wmove(ctx.rows - 1, 0)
                win:waddstr(string.format('%16s ', label))
                dashboard.draw_load(win, tracker.global)
                draw.normal(win)
            end
        end,

        status = function(ctx, win)
            dashboard.load_status(ctx, win, 'cliconn', 'conn')
        end,
    }
end

return {
    make_view('banload', 'K-Liner', 'KLINES', 'K-Line History', 'kline'),
    make_view('spamload', 'Server', 'FILTERS', 'Filter History', 'filter'),
}
