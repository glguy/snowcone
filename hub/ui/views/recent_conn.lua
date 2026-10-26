-- Recent connections (cliconn) and exits (cliexit), from the dashboard's
-- view/recent_conn.lua.
--
-- Click a mask to stage a K-Line (or an unkline for a K-Lined user); click
-- a server to show only it. q shows live users, w exits, e both.
-- View state: scroll, filter, prefilter (a /prefilter query), server_filter,
-- conn_filter, mark_filter, highlight, show_reasons.

local addircstr <const> = require 'hub.ui.irc_formatting'
local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local matching  <const> = require 'hub.lib.matching'
local matchdsl  <const> = require 'hub.lib.matchdsl'
local oper      <const> = require 'hub.features.oper'
local scrub     <const> = require 'hub.lib.scrub'

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
        local safematch = matching.safematch
        return function(entry)
            if prefilter and not prefilter(entry) then
                return false
            end
            return (vs.server_filter == nil or vs.server_filter == entry.server)
               and (vs.conn_filter == nil or vs.conn_filter == not entry.reason)
               and (vs.mark_filter == nil or vs.mark_filter == entry.mark)
               and (pattern == nil
                    or safematch(entry.mask, pattern)
                    or entry.account and safematch(entry.account, pattern)
                    or entry.gecos and safematch(entry.gecos, pattern)
                    or entry.ip and safematch(entry.ip, pattern)
                    or entry.org and safematch(entry.org, pattern)
                    or entry.asn and safematch('AS' .. entry.asn, pattern)
                    or entry.reason and safematch(entry.reason, pattern))
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
        local mask_colour = entry.reason and draw.red or draw.green

        -- filter hits or reconnect count
        if entry.filters then
            mask_colour(win)
            win:waddstr(string.format(' %3d!', entry.filters))
        elseif entry.count then
            if entry.count < 2 then draw.black(win) else draw.normal(win) end
            win:waddstr(string.format(' %4d', entry.count))
        else
            win:waddstr '     '
        end

        if entry.mark then
            local colour = dashboard.colour(entry.mark)
            if colour then colour(win) end
            ctx.add_button(win, '◆', function() vs.mark_filter = entry.mark end, true)
        else
            win:waddstr ' '
        end

        -- mask
        if vs.highlight == entry.mask then draw.bold(win) end
        win:wmove(y, 14)
        mask_colour(win)
        win:waddstr(scrub(entry.nick))
        draw.black(win)
        win:waddstr '!'
        mask_colour(win)
        win:waddstr(scrub(entry.user))
        draw.black(win)
        win:waddstr '@'
        mask_colour(win)
        local maxwidth = 63 - #entry.nick - #entry.user
        if #entry.host <= maxwidth then
            win:waddstr(scrub(entry.host))
            draw.normal(win)
        else
            win:waddstr(scrub(entry.host:sub(1, maxwidth - 1)))
            draw.normal(win)
            win:waddstr '…'
        end

        -- address, organisation or reason
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
            win:waddstr(entry.ip)
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
            win:waddstr(string.format('%-3.3s ', entry.server))
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

        ctx.add_click(y, 14, 79, function()
            if entry.reason == 'K-Lined' then
                oper.entry_to_unkline(net, entry)
            else
                oper.entry_to_kline(net, entry)
            end
            vs.highlight = entry.mask
        end)
    end

    return {
        id = id,
        title = title,
        scope = 'net',

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
            -- the active filters, as one fragment
            local vs = ctx.vs
            local words = {}
            if vs.conn_filter ~= nil then
                table.insert(words, {vs.conn_filter and draw.green or draw.red, vs.conn_filter and 'LIVE' or 'DEAD'})
            end
            if vs.server_filter then table.insert(words, {draw.yellow, 'SERVER'}) end
            if vs.mark_filter then table.insert(words, {draw.yellow, 'MARKED'}) end
            if vs.prefilter then table.insert(words, {draw.yellow, 'PF'}) end
            if #words > 0 then
                ctx.fragment(win)
                for i, w in ipairs(words) do
                    w[1](win)
                    win:waddstr((i > 1 and ' ' or '') .. w[2])
                end
                draw.normal(win)
            end
        end,
    }
end

return {
    make_view('cliconn', 'cliconn', 'users', 'conn'),
    make_view('cliexit', 'cliexit', 'exits', 'exit'),

    commands = {
        {
            name = 'prefilter',
            spec = '$R',
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
