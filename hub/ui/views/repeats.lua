-- Nicks and masks that keep reconnecting.

local dashboard  <const> = require 'hub.ui.dashboard'
local draw       <const> = require 'hub.ui.draw'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local scrub      <const> = require 'hub.lib.scrub'

local function top_keys(tab)
    local result = {}
    for k, v in pairs(tab) do
        table.insert(result, {k, v})
    end
    table.sort(result, function(x, y)
        if x[2] == y[2] then return x[1] < y[1] end
        return x[2] > y[2]
    end)
    return result
end

return {
    id = 'repeats',
    title = 'repeats',
    scope = 'net',
    feature = 'snotice',

    render = function(ctx, win)
        local S = dashboard.stores(ctx, win)
        if not S then return end

        local nick_counts, mask_counts = {}, {}
        for user, key in OrderedMap.each(S.users) do
            nick_counts[user.nick] = (nick_counts[user.nick] or 0) + 1
            mask_counts[key] = user.count
        end
        local nicks = top_keys(nick_counts)
        local masks = top_keys(mask_counts)

        for i = 1, ctx.rows do
            local nick = nicks[i]
            if nick and nick[2] > 1 then
                win:wmove(i - 1, 0)
                win:waddstr(string.format('%4d ', nick[2]))
                draw.blue(win)
                win:waddstr(string.format('%-16s', scrub(nick[1])))
                draw.normal(win)
            end
            local mask = masks[i]
            if mask then
                win:wmove(i - 1, 22)
                win:waddstr(string.format('%4d ', mask[2]))
                draw.yellow(win)
                win:waddstr(scrub(mask[1]))
                draw.normal(win)
            end
        end
    end,

    status = function(ctx, win)
        dashboard.load_status(ctx, win, 'cliconn', 'conn')
    end,
}
