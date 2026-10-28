-- Users per address range, and the connection watches.

local control   <const> = require 'hub.ui.control'
local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local nettrack  <const> = require 'hub.features.snotice.nettrack'
local scrub     <const> = require 'hub.lib.scrub'

local function sorted_keys(t, less)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    if less then
        table.sort(keys, function(x, y) return less(t[x], t[y]) end)
    else
        table.sort(keys)
    end
    return keys
end

local function ordermask(a, b)
    if a.addrlen ~= b.addrlen then return a.addrlen < b.addrlen end
    if a.network ~= b.network then return a.network < b.network end
    return (a.tailbyte or 0) < (b.tailbyte or 0)
end

local function render_entry(win, y, name, count, nested)
    win:wmove(y, 0)
    if nested then
        win:waddstr(string.format('%43s┘  ', scrub(name)))
    else
        draw.bold(win)
        win:waddstr(string.format('%44s  ', scrub(name)))
        draw.bold_(win)
    end
    dashboard.add_population(win, count)
    win:waddstr '  '
end

local function toggle(ctx, win, watch, field, on, off)
    win:waddstr ' '
    if watch[field] then
        draw.green(win)
        ctx.add_button(win, on, function() watch[field] = nil end)
    else
        draw.yellow(win)
        ctx.add_button(win, off, function() watch[field] = true end)
    end
end

return {
    id = 'netcount',
    title = 'netcount',
    scope = 'net',
    feature = 'snotice',

    render = function(ctx, win)
        local S = dashboard.stores(ctx, win)
        if not S then return end
        local vs = ctx.vs
        vs.expanded = vs.expanded or {}

        draw.magenta(win)
        draw.bold(win)
        win:wmove(0, 37)
        win:waddstr 'Network  Count  Actions'
        draw.normal(win)

        local y = 1
        for _, name in ipairs(sorted_keys(S.net_trackers)) do
            if y + 1 >= ctx.rows then break end
            local tracker = S.net_trackers[name]
            draw.cyan(win)
            render_entry(win, y, name, nettrack.total(tracker))
            draw.red(win)
            ctx.add_button(win, '(x)', function() S.net_trackers[name] = nil end)
            win:waddstr ' '
            if vs.expanded[name] then
                draw.yellow(win)
                ctx.add_button(win, '(-)', function() vs.expanded[name] = nil end)
                for _, label in ipairs(sorted_keys(tracker, ordermask)) do
                    y = y + 1
                    if y + 1 >= ctx.rows then break end
                    draw.blue(win)
                    render_entry(win, y, label, tracker[label].count, true)
                    draw.red(win)
                    ctx.add_button(win, '(x)', function() tracker[label] = nil end)
                end
            else
                draw.green(win)
                ctx.add_button(win, '(+)', function() vs.expanded[name] = true end)
            end
            y = y + 1
        end

        y = y + 1
        if y + 1 < ctx.rows and next(S.watches) then
            draw.green(win)
            win:wmove(y, 0)
            win:waddstr 'Actions                Watch Hits Pattern'
            y = y + 1
        end

        for i, watch in ipairs(S.watches) do
            if y + 1 >= ctx.rows then break end
            win:wmove(y, 0)
            draw.red(win)
            ctx.add_button(win, '(x)', function() table.remove(S.watches, i) end)
            toggle(ctx, win, watch, 'active', '(A)', '(a)')
            toggle(ctx, win, watch, 'beep', '(B)', '(b)')
            toggle(ctx, win, watch, 'flash', '(F)', '(f)')
            draw.normal(win)
            win:waddstr ' '
            ctx.add_button(win, '[show]', function()
                control.set_filter('cliconn', watch.pattern)
                control.set_view 'cliconn'
            end)
            win:waddstr(string.format(' %3d ', i))
            ;(dashboard.colour(watch.colour) or draw.red)(win)
            win:waddstr '◆'
            draw.blue(win)
            win:waddstr(string.format(' %4d', watch.hits))
            draw.normal(win)
            win:waddstr(string.format(' %-40s', scrub(watch.pattern)))
            y = y + 1
        end
    end,

    status = function(ctx, win)
        dashboard.load_status(ctx, win, 'cliconn', 'conn')
    end,
}
