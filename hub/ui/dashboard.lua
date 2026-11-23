-- Drawing shared by the dashboard views: load averages, populations, the
-- action bar for ban staging, and the load in the status bar.

local common   <const> = require 'hub.features.common'
local config_schema <const> = require 'hub.runtime.config_schema'
local draw     <const> = require 'hub.ui.draw'
local loadavg  <const> = require 'hub.lib.loadavg'
local oper     <const> = require 'hub.features.oper'
local scrub    <const> = require 'hub.lib.scrub'
local stores   <const> = require 'hub.features.snotice.stores'
local topology <const> = require 'hub.features.topology'

local M = {}

--- The notice stores of the view's network, or nil after drawing why not.
function M.stores(ctx, win)
    if not ctx.net then
        win:waddstr 'No network selected\n'
        return nil
    end
    if not common.enabled(ctx.net, 'snotice') then
        win:waddstr(ctx.net .. ' does not have the snotice feature\n')
        return nil
    end
    return stores.get(ctx.net)
end

--- The topology of the view's network (empty without the feature).
function M.topology(ctx)
    return topology.get(ctx.net)
end

local function draw_load_1(win, avg, i)
    if avg.n >= 60 * i then
        draw.bold(win)
        win:waddstr(string.format('%5.2f ', avg[i]))
        draw.bold_(win)
    else
        win:waddstr(string.format('%5.2f ', avg[i]))
    end
end

--- 1, 5 and 15 minute averages and the last minute's graph.
function M.draw_load(win, avg)
    draw_load_1(win, avg, 1)
    draw_load_1(win, avg, 5)
    draw_load_1(win, avg, 15)
    win:waddstr '['
    draw.underline(win)
    win:waddstr(loadavg.graph(avg))
    draw.underline_(win)
    win:waddstr ']'
end

--- A user count, thousands in bold.
function M.add_population(win, pop)
    if pop then
        if pop < 1000 then
            win:waddstr(string.format('%5d', pop))
        else
            draw.bold(win)
            win:waddstr(string.format('%2d', pop // 1000))
            draw.bold_(win)
            win:waddstr(string.format('%03d', pop % 1000))
        end
    else
        win:waddstr '    ?'
    end
end

--- Status bar segment: a tracker's global load.
function M.load_status(ctx, win, label, which)
    if not (ctx.net and common.enabled(ctx.net, 'snotice')) then return end
    local tracker = stores.get(ctx.net).trackers[which]
    ctx.fragment(win)
    draw.magenta(win)
    win:waddstr(label .. ' ')
    M.draw_load(win, tracker.global)
    draw.normal(win)
end

--- Draw function for a color name, or nil.
function M.color(name)
    if name and config_schema.colors[name] then return draw[name] end
end

-- Action bar ==========================================================

local show_cycle <const> = {
    reason = {'org', 'ip'},
    org = {'asn', 'reason'},
    asn = {'ip', 'org'},
    ip = {'reason', 'asn'},
}

local show_labels <const> = {reason = 'REASON', org = ' ORG  ', asn = ' ASN  ', ip = '  IP  '}

--- The bottom row of the connection and ban views: what the reason column
--- shows, the ban settings, and the staged action with its buttons.
function M.action_bar(ctx, win, y)
    local net = ctx.net
    if not (net and common.enabled(net, 'oper')) then return end
    local O = oper.get(net)
    local settings = O.settings
    local vs = ctx.vs

    win:wmove(y, 0)
    draw.bold(win)

    -- the colors set before neutral chips show on the classic theme
    draw.yellow(win)
    local shown = vs.show_reasons or 'reason'
    ctx.add_chip(win, show_labels[shown], function(shifted)
        vs.show_reasons = show_cycle[shown][shifted and 2 or 1]
    end)
    ctx.chip_gap(win)

    if vs.filter then
        ctx.add_chip(win, 'CLEAR FILTER', function() vs.filter = nil end, 'accent')
        ctx.chip_gap(win)
    end

    draw.cyan(win)
    ctx.add_chip(win, settings.duration, function(shifted)
        oper.cycle_duration(net, shifted)
    end)
    ctx.chip_gap(win)

    draw.blue(win)
    ctx.add_chip(win, settings.trust_uname and '~' or '=', function()
        oper.toggle_trust(net)
    end)
    ctx.chip_gap(win)

    ctx.add_chip(win, settings.add_freeze and 'FR' or '  ', function()
        oper.toggle_freeze(net)
    end, settings.add_freeze and (settings.tag and 'danger' or 'warn') or nil)
    ctx.chip_gap(win)

    draw.magenta(win)
    local reasons = oper.reasons(net)
    local reason = reasons[settings.reason] or reasons[1]
    ctx.add_chip(win, string.format('%-7s', reason.name), function(shifted)
        oper.cycle_reason(net, shifted)
    end)
    ctx.chip_gap(win)

    ctx.add_chip(win, string.format('%-7s', settings.tag or 'no tag'), function(shifted)
        oper.cycle_tag(net, shifted)
    end)
    ctx.chip_gap(win)

    local staged = O.staged
    if staged and staged.action == 'kline' then
        draw.green(win)
        ctx.add_chip(win, 'CANCEL KLINE', function()
            oper.cancel(net)
            vs.highlight = nil
        end)
        ctx.chip_gap(win)
        local freeze = oper.freeze_account(net)
        local text = string.format('KLINE %s %s %s%s',
            staged.count and tostring(staged.count) or '?',
            staged.nick or '*',
            staged.mask,
            freeze and ' FREEZE ' .. freeze or '')
        ctx.add_chip(win, scrub(text), function() oper.commit(net) end, 'danger')
        ctx.chip_gap(win)
        ctx.add_chip(win, 'TRACE', function() oper.trace(net) end, 'warn')
    elseif staged and staged.action == 'unkline' and staged.mask then
        draw.green(win)
        ctx.add_chip(win, 'CANCEL UNKLINE', function()
            oper.cancel(net)
            vs.highlight = nil
        end)
        ctx.chip_gap(win)
        ctx.add_chip(win, scrub(string.format('UNKLINE %s %s', staged.nick or '*', staged.mask)),
            function() oper.commit(net) end, 'warn')
    elseif staged and staged.action == 'undline' then
        draw.green(win)
        ctx.add_chip(win, 'CANCEL UNDLINE', function() oper.cancel(net) end)
        ctx.chip_gap(win)
        ctx.add_chip(win, scrub(string.format('UNDLINE %s', staged.mask)),
            function() oper.commit(net) end, 'warn')
    end

    draw.normal(win)
end

return M
