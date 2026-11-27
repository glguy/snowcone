-- Recent connections (cliconn) and exits (cliexit).
--
-- Clicks: a mask stages a K-Line, or an unkline for a K-Lined user (with
-- the oper feature); a server shows only it; a ◆ shows only the entries
-- with that mark. The action bar's first chip cycles what the reason
-- column shows: the reason, organization, ASN or address.
--
-- Keys: q shows live users only, w exits only, e both. Esc clears the
-- server, live and mark filters and the highlight. /prefilter sets a
-- query (lib/matchdsl.lua) these views keep until it is cleared.
--
-- A ban staged from another view, as by /kline, shows cliconn, where it
-- is sent.
--
-- View state: scroll, filter, prefilter (a /prefilter query),
-- server_filter, conn_filter, mark_filter, highlight (the mask staged),
-- show_reasons.

local addircstr <const> = require 'hub.ui.irc_formatting'
local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local matchdsl  <const> = require 'hub.lib.matchdsl'
local oper      <const> = require 'hub.features.oper'
local scrub     <const> = require 'hub.lib.scrub'
local stores    <const> = require 'hub.features.snotice.stores'

-- Compiled /prefilter queries, by source; rebuilt after a reload
local compiled = {}

local function prefilter_of(vs)
    local src = vs.prefilter
    if not src then return nil end
    local f = compiled[src]
    if f == nil then
        local ok, result = pcall(matchdsl, src)
        f = ok and result or false
        compiled[src] = f
    end
    return f or nil
end

local function make_view(id, title, store, tracker)
    local function show_entry(vs, pattern, prefilter)
        return function(entry)
            if prefilter and not prefilter(entry) then
                return false
            end
            return (vs.server_filter == nil or vs.server_filter == entry.server)
               and (vs.conn_filter == nil or vs.conn_filter == not entry.reason)
               and (vs.mark_filter == nil or vs.mark_filter == entry.mark)
               and (pattern == nil or stores.matches(entry, pattern))
        end
    end

    local keys = {
        [string.byte 'q'] = function(ctx) ctx.vs.conn_filter = true end,
        [string.byte 'w'] = function(ctx) ctx.vs.conn_filter = false end,
        [string.byte 'e'] = function(ctx) ctx.vs.conn_filter = nil end,
    }

    local function draw_entry(ctx, win, entry)
        local vs = ctx.vs
        local net = ctx.net
        local y = ncurses.getyx(win)
        local mask_color = entry.reason and draw.red or draw.green

        -- filter hits or reconnect count
        if entry.filters then
            mask_color(win)
            win:waddstr(string.format(' %3d!', entry.filters))
        elseif entry.count then
            if entry.count < 2 then draw.muted(win) else draw.normal(win) end
            win:waddstr(string.format(' %4d', entry.count))
        else
            win:waddstr '     '
        end

        if entry.mark then
            local color = dashboard.color(entry.mark)
            if color then color(win) end
            ctx.add_button(win, '◆', function() vs.mark_filter = entry.mark end, true)
        else
            win:waddstr ' '
        end

        -- mask
        if vs.highlight == entry.mask then draw.bold(win) end
        win:wmove(y, 14)
        mask_color(win)
        win:waddstr(scrub(entry.nick))
        draw.muted(win)
        win:waddstr '!'
        mask_color(win)
        win:waddstr(scrub(entry.user))
        draw.muted(win)
        win:waddstr '@'
        mask_color(win)
        local maxwidth = 63 - #entry.nick - #entry.user
        if #entry.host <= maxwidth then
            win:waddstr(scrub(entry.host))
            draw.normal(win)
        else
            win:waddstr(scrub(entry.host:sub(1, maxwidth - 1)))
            draw.normal(win)
            win:waddstr '…'
        end

        -- address, organization or reason
        if not entry.reason then
            draw.yellow(win)
        elseif entry.reason == 'K-Lined' then
            draw.red(win)
        else
            draw.magenta(win)
        end
        win:wmove(y, 80)
        local shown = vs.show_reasons or 'reason'
        if shown == 'reason' and entry.reason then
            win:waddstr(scrub(entry.reason):sub(1, 39))
        elseif shown == 'asn' and entry.asn then
            win:waddstr(string.format('AS%-6d %-30.30s', entry.asn, scrub(entry.org or '')))
        elseif shown ~= 'ip' and entry.org then
            win:waddstr(scrub(entry.org):sub(1, 39))
        elseif entry.ip then
            win:waddstr(scrub(entry.ip))
        else
            win:waddstr '·'
        end

        -- server
        draw.blue(win)
        win:wmove(y, 120)
        local info = common.servers(net).servers[entry.server] or {}
        if info.alias then
            win:waddstr(string.format('%-2.2s ', info.alias))
        else
            win:waddstr(string.format('%-3.3s ', scrub(entry.server)))
        end
        ctx.add_click(y, 120, 122, function() vs.server_filter = entry.server end)

        -- account and gecos
        draw.normal(win)
        if entry.account == '*' then
            draw.cyan(win)
            win:waddstr '· '
        elseif entry.account then
            draw.cyan(win)
            win:waddstr(scrub(entry.account) .. ' ')
        end
        if entry.gecos then
            addircstr(win, entry.gecos)
        end

        -- staging belongs to the oper feature, which shows what it stages
        if common.enabled(net, 'oper') then
            ctx.add_click(y, 14, 79, function()
                if entry.reason == 'K-Lined' then
                    oper.entry_to_unkline(net, entry)
                else
                    oper.entry_to_kline(net, entry)
                end
                vs.highlight = entry.mask
            end)
        end
    end

    return {
        id = id,
        title = title,
        scope = 'net',
        feature = 'snotice',

        render = function(ctx, win)
            local S = dashboard.stores(ctx, win)
            if not S then return end
            local data = S[store]
            local vs = ctx.vs
            local show = show_entry(vs, control.filter(id), prefilter_of(vs))
            draw.draw_rotation(win, vs, 0, math.max(1, ctx.rows - 1), data, show, function(w, entry)
                draw_entry(ctx, w, entry)
            end)
            dashboard.action_bar(ctx, win, ctx.rows - 1)
        end,

        keypress = function(ctx, key)
            local h = keys[key]
            if h and ctx.net then
                h(ctx)
                return true
            end
        end,

        reset = function(vs)
            vs.server_filter = nil
            vs.conn_filter = nil
            vs.mark_filter = nil
            vs.highlight = nil
        end,

        status = function(ctx, win)
            dashboard.load_status(ctx, win, id, tracker)
        end,

        modes = function(ctx)
            local vs = ctx.vs
            local modes = {}
            if vs.conn_filter ~= nil then
                table.insert(modes, vs.conn_filter and 'live' or 'dead')
            end
            if vs.server_filter then table.insert(modes, 'server') end
            if vs.mark_filter then table.insert(modes, 'marked') end
            if vs.prefilter then table.insert(modes, 'pf') end
            return modes
        end,
    }
end

-- The views that show the action bar, where a staged ban is sent
local action_views <const> = {cliconn = true, cliexit = true, bans = true}

return {
    make_view('cliconn', 'cliconn', 'users', 'conn'),
    make_view('cliexit', 'cliexit', 'exits', 'exit'),

    -- a ban staged elsewhere, as by /kline, shows cliconn, where it's sent;
    -- not for a network not shown, which cliconn wouldn't show it for
    subscribe = function(sub)
        sub.on('oper.staged', function(ev)
            if ev.net == control.current_net() and common.enabled(ev.net, 'snotice')
                and not action_views[HUB.state.ui.view] then
                control.set_view 'cliconn'
            end
        end)
    end,

    commands = {
        {
            name = 'prefilter',
            spec = '$R',
            usage = '[query]',
            group = 'snotice',
            scope = 'net',
            feature = 'snotice',
            help = "Query for cliconn/cliexit: nick |re| and not (account '*' or server 'x'); empty clears",
            fn = function(_, query)
                local view = HUB.state.ui.view
                if view ~= 'cliconn' and view ~= 'cliexit' then
                    view = 'cliconn'
                end
                if query == '' then
                    control.view_state(view).prefilter = nil
                    return
                end
                matchdsl(query) -- raises on a bad query
                control.view_state(view).prefilter = query
            end,
        },
    },
}
