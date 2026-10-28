-- Bans, unbans and kills.
--
-- Click an active K-Line's mask to stage removing it (TESTLINE shows its
-- details), or a D-Line's to stage an undline.

local control    <const> = require 'hub.ui.control'
local dashboard  <const> = require 'hub.ui.dashboard'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'
local oper       <const> = require 'hub.features.oper'
local scrub      <const> = require 'hub.lib.scrub'

local palette <const> = {
    kline = draw.red,
    expired = draw.yellow,
    removed = draw.green,
    inactive = draw.normal,
    kill = draw.magenta,
    dline = draw.cyan,
}

local function match_key(t, pat)
    for k in pairs(t or {}) do
        if matching.safematch(k, pat) then return true end
    end
end

local function draw_entry(ctx, win, entry)
    local oper_name
    if entry.oper and entry.oper:find '%.' then
        draw.yellow(win)
        oper_name = entry.oper:match '^(.-)%.'
    else
        draw.green(win)
        oper_name = entry.oper or ''
    end
    win:waddstr(string.format(' %-12.12s ', scrub(oper_name)))

    if entry.duration then
        draw.yellow(win)
        win:waddstr(string.format('%7s ', oper.pretty_duration(entry.duration) or ''))
    else
        draw.normal(win)
        win:waddstr(string.format('%7.7s ', entry.kind))
    end

    local y, x = ncurses.getyx(win)
    if entry.kind == 'kline' then
        ctx.add_click(y, x, x + #entry.mask, function() oper.stage_unkline(ctx.net, entry.mask) end)
    elseif entry.kind == 'dline' then
        ctx.add_click(y, x, x + #entry.mask, function() oper.stage_undline(ctx.net, entry.mask) end)
    end

    ;(palette[entry.kind] or draw.normal)(win)
    win:waddstr(string.format('%-30s ', scrub(entry.mask)))

    local nicks = entry.nicks
    if nicks then
        local xs, i, n = {}, 0, 0
        for k, v in pairs(nicks) do
            i = i + 1
            n = n + v
            xs[i] = v > 1 and string.format('%s:%d', k, v) or k
            if i == 50 then break end
        end
        if i < 8 then
            draw.normal(win)
            table.sort(xs)
            win:waddstr(scrub(table.concat(xs, ' ')) .. ' ')
        elseif i < 50 then
            draw.magenta(win)
            win:waddstr(string.format('%d nicks %d hits ', i, n))
        else
            draw.magenta(win)
            win:waddstr 'many affected '
        end
    end

    draw.blue(win)
    if entry.reason then
        win:waddstr(scrub(entry.reason))
    end
end

return {
    id = 'bans',
    title = 'bans',
    scope = 'net',
    feature = 'snotice',

    render = function(ctx, win)
        local S = dashboard.stores(ctx, win)
        if not S then return end
        draw.bold(win)
        draw.magenta(win)
        win:waddstr 'time     operator    duration mask                           affected users and reason'
        draw.bold_(win)

        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(entry)
                return matching.safematch(entry.mask, pattern)
                    or entry.reason and matching.safematch(entry.reason, pattern)
                    or match_key(entry.nicks, pattern)
            end
        end
        draw.draw_rotation(win, ctx.vs, 1, math.max(0, ctx.rows - 2), S.klines, show, function(w, entry)
            draw_entry(ctx, w, entry)
        end)
        dashboard.action_bar(ctx, win, ctx.rows - 1)
    end,

    reset = function(vs) vs.highlight = nil end,

    status = function(ctx, win)
        dashboard.load_status(ctx, win, 'cliconn', 'conn')
    end,
}
