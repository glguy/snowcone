-- Terminal UI: layout, the draw function and the native entry points.
-- Only this layer touches ncurses.
--
-- Windows are handles, not data, so each generation makes its own when it
-- becomes current and on every resize.

local chat      <const> = require 'hub.features.chat'
local clicks    <const> = require 'hub.ui.clicks'
local control   <const> = require 'hub.ui.control'
local details   <const> = require 'hub.ui.details'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'
local keymap    <const> = require 'hub.ui.keymap'
local pads      <const> = require 'hub.ui.pads'
local statusbar <const> = require 'hub.ui.statusbar'
local dispatch  <const> = require 'hub.runtime.dispatch'
local log       <const> = require 'hub.runtime.log'
local tty       <const> = require 'hub.runtime.tty'

local M = {}

local pad_width <const> = pads.width

local layout = {textbox_offset = 0, detail_rows = 0}

local function make_layout()
    if layout.main_pad then layout.main_pad:delwin() end
    layout.main_pad = ncurses.newpad(tty_height - 1, pad_width)

    -- the detail pane and document views wrap at the terminal's width
    -- and grow downward
    if layout.detail_pad then layout.detail_pad:delwin() end
    layout.detail_pad = ncurses.newpad(tty_height - 1, tty_width)
    if layout.document_pad then layout.document_pad:delwin() end
    layout.document_pad = ncurses.newpad(tty_height - 1, tty_width)

    if layout.input_win then layout.input_win:delwin() end
    layout.input_win = ncurses.newwin(1, tty_width, tty_height - 1, 0)

    if layout.textbox_pad then layout.textbox_pad:delwin() end
    layout.textbox_pad = ncurses.newpad(1, 1024)
end

--- Context handed to a view's render, keypress and status functions.
--- What a view's render and key handlers get.
---@class hub.ViewContext
---@field id string the view's id
---@field vs hub.ViewState
---@field net string|nil the current network
---@field rows integer
---@field cols integer
---@field add_click fun(y: integer, lo: integer, hi: integer, action: fun())
---@field add_button fun(win: ncurses.Window, text: string, action: fun(), plain: boolean|nil)
---@field fragment fun(win: ncurses.Window, bg: integer|nil)|nil starts a fragment of the
--- status bar, while a view draws its status (ui/statusbar.lua)

-- The view gets the rows below the detail pane
---@return hub.ViewContext
local function view_context(view)
    return {
        id = view.id,
        vs = control.view_state(view.id),
        net = control.current_net(),
        rows = tty_height - 1 - layout.detail_rows,
        cols = tty_width,
        add_click = clicks.add,
        add_button = clicks.button,
    }
end

-- Render a document view into its pad, shown from row vs.scroll on the
-- screen rows from `at`. Returns the refresh to do.
local function render_document(view, ctx, at)
    local pad, vs, rows = layout.document_pad, ctx.vs, ctx.rows
    pads.set_paging(vs, pads.draw_grown(pad, tty_width, function(win) view.render(ctx, win) end), rows)
    local top = vs.scroll
    clicks.place(top, rows, at)

    return function()
        pad:pnoutrefresh(top, 0, at, 0, tty_height - 2, tty_width - 1)
    end
end

local function render()
    if tty.suspended() then return end

    clicks.reset()
    local main_pad, input_win, textbox_pad = layout.main_pad, layout.input_win, layout.textbox_pad
    ncurses.erase()
    main_pad:werase()
    input_win:werase()
    textbox_pad:werase()

    -- the detail pane first: the view gets the rows it leaves
    local detail = control.detail()
    local kind = detail and details.kinds[detail.kind]
    if detail and not kind then
        control.close_detail() -- a reload removed its renderer
    end
    local refresh_detail
    layout.detail_rows = 0
    if kind then
        layout.detail_rows, refresh_detail = details.render(detail, kind, layout.detail_pad)
    end
    local at = layout.detail_rows

    local view = control.current_view()
    local ctx = view_context(view)

    local refresh
    if view.document then
        refresh = render_document(view, ctx, at)
    else
        draw.normal(main_pad)
        view.render(ctx, main_pad)
        local hscroll = math.max(0, math.min(ctx.vs.hscroll or 0, pad_width - tty_width))
        clicks.place(0, ctx.rows, at, hscroll)
        refresh = function()
            main_pad:pnoutrefresh(0, hscroll, at, 0, tty_height - 2, tty_width - 1)
        end
    end

    -- the status bar's clicks are in screen rows already
    statusbar.draw(input_win, textbox_pad, layout, view, ctx)
    clicks.place(tty_height - 1, 1, tty_height - 1)

    ncurses.noutrefresh()
    if refresh_detail then refresh_detail() end
    refresh()
    ncurses.noutrefresh(input_win)

    if HUB.state.ui.input.mode then
        local _, ix = ncurses.getyx(input_win)
        textbox_pad:pnoutrefresh(0, layout.textbox_offset, tty_height - 1, ix, tty_height - 1, tty_width - 1)
    end
    ncurses.doupdate()
end

-- Native entry points ================================================

local entry = {}

function entry.on_keyboard(key)
    dispatch.dirty()
    local mode = HUB.state.ui.input.mode

    -- text goes to the input box
    if mode and 0x20 <= key and (key < 0x7f or 0xa0 <= key) then
        editor.add(control.editor(), key)
        return
    end

    if mode then
        local f = keymap.input[key]
        if f then
            f()
            return
        end
    end

    -- then the detail pane, and the view, before the global keys; true
    -- consumes the key
    local detail = control.detail()
    local kind = detail and details.kinds[detail.kind]
    if kind and kind.keypress and kind.keypress(details.context(detail, layout.detail_rows), key) then
        return
    end

    local view = control.current_view()
    if view.keypress and view.keypress(view_context(view), key) then
        return
    end

    local f = keymap.global[key]
    if f then f() end
end

-- A paste over the native limit arrives as nil and its size
function entry.on_paste(paste, size)
    if paste == nil then
        log.error('paste', string.format('a paste of %s bytes was discarded (limit 64 KiB)', size))
        dispatch.dirty()
        return
    end
    if HUB.state.ui.input.mode then
        local ed = control.editor()
        for _, c in utf8.codes(paste) do
            -- paste up to the first newline or nul
            if c == 0 or c == 10 or c == 13 then
                break
            end
            editor.add(ed, c)
        end
        dispatch.dirty()
    end
end

function entry.on_mouse(y, x, shifted)
    if clicks.hit(y, x, shifted) then
        dispatch.dirty()
    end
end

function entry.on_resize()
    make_layout()
    dispatch.dirty()
end

-- ^C, kill or a closed terminal: the first starts quitting, the next
-- shuts down at once, and after shutdown the signal ends the process
function entry.on_signal(name)
    log.add('app', 'received %s', name)
    dispatch.route 'app.quit' ()
end

function entry.print(str)
    log.add('print', '%s', str)
end

-- Module interface ===================================================

M.init_state = control.init_state

-- A view module returns a view or a list of views, and may bring commands
-- of its own in `commands`. Each view also gets a command that shows it,
-- unless it sets command = false.
local view_modules <const> = {
    require 'hub.ui.views.bans',
    require 'hub.ui.views.bouncer',
    require 'hub.ui.views.buffer',
    require 'hub.ui.views.list',
    require 'hub.ui.views.channels',
    require 'hub.ui.views.netcount',
    require 'hub.ui.views.repeats',
    require 'hub.ui.views.console',
    require 'hub.ui.views.help',
    require 'hub.ui.views.networks',
    require 'hub.ui.views.plugins',
    require 'hub.ui.views.session',
    require 'hub.ui.views.stats',
    require 'hub.ui.views.status',
    require 'hub.ui.views.recent_conn',
    require 'hub.ui.views.server_load',
    require 'hub.ui.views.simple_load',
}

M.views = {}
M.commands = {
    {
        name = 'filter',
        spec = '$R',
        usage = '[pattern]',
        group = 'client',
        help = 'Show only lines of this view, or of the detail pane, that match; no pattern clears it',
        fn = function(_, pattern)
            control.set_filter(details.filter_target(), pattern)
        end,
    },
    {
        name = 'profile',
        spec = '$g',
        usage = 'dashboard|chat|all',
        group = 'client',
        help = 'Switch the view rotation',
        fn = function(_, name)
            if not control.profiles[name] then
                error('unknown profile: ' .. name, 0)
            end
            HUB.state.ui.profile = name
            dispatch.dirty()
        end,
    },
    {
        name = 'net',
        spec = '$g',
        usage = 'network',
        group = 'client',
        help = 'Choose the network that views and commands act on',
        fn = function(_, id)
            control.set_current_net(id)
        end,
    },
}

for _, m in ipairs(view_modules) do
    for _, view in ipairs(m.id and {m} or m) do
        table.insert(M.views, view)
        -- a view for a feature has a command for that feature, which
        -- also takes a network (/name@network) to show that network's view
        if view.command ~= false then
            table.insert(M.commands, {
                name = view.id,
                spec = '',
                help = 'Show the ' .. view.title .. ' view',
                -- /help lists the views together, by name
                group = 'views',
                scope = view.feature and 'net' or nil,
                feature = view.feature,
                fn = function(ctx)
                    if view.feature then control.set_current_net(ctx.net) end
                    control.set_view(view.id)
                end,
            })
        end
    end
    for _, cmd in ipairs(m.commands or {}) do
        table.insert(M.commands, cmd)
    end
end

function M.subscribe(sub)
    sub.on('task.prompt', control.add_prompt)
    sub.on('chat.focus', function(ev)
        control.set_current_net(ev.net)
        control.set_talk_target(ev.net, ev.target)
        control.set_view 'buffer'
    end)
    -- closing the shown buffer moves to one with a mention, else back to
    -- the previous one (as after Meta-A into a query), else one with
    -- activity, else the next by name; Meta-S no longer goes back to a
    -- closed buffer
    sub.on('chat.buffer', function(ev)
        if ev.opened then return end
        local net = ev.net
        local key = chat.fold(net, ev.target)
        local vs = control.view_state 'buffer'
        local previous = vs.previous and vs.previous[net]
        if previous and chat.fold(net, previous) == key then
            previous = nil
            vs.previous[net] = nil
        end
        local current = control.talk_target(net)
        if current and chat.fold(net, current) == key then
            local best = chat.next_buffer(net, key, true)
            if not (best and best.mention) then
                best = previous and chat.buffer(net, previous)
                    or best or chat.next_buffer(net, key)
            end
            control.set_talk_target(net, best and best.name)
            if best and previous and chat.fold(net, previous) == chat.fold(net, best.name) then
                previous = nil
            end
            vs.previous[net] = previous
        end
    end)
    sub.on('quote.sent', function(ev)
        control.open_detail('reply', ev.net, ev.reply)
    end)
    sub.on('chat.whois', function(ev)
        control.open_detail('whois', ev.net, ev.whois)
    end)
    sub.on('chat.whowas', function(ev)
        control.open_detail('whowas', ev.net, ev.whowas)
    end)
    sub.on('eval.result', function(ev)
        control.open_detail('value', nil, ev.value)
    end)
    sub.on('chat.show_channel', function(ev)
        control.open_detail('channel', ev.net, {name = ev.target})
    end)
    sub.on('chat.show_list', function(ev)
        control.set_current_net(ev.net)
        control.set_view 'list'
    end)
    -- the UI decides how to get attention
    sub.on('notify.alert', function(ev)
        if ev.beep then ncurses.beep() end
        if ev.flash then ncurses.flash() end
    end)
    sub.on('chat.message', function() dispatch.dirty() end)
end

M.routes = {
    ['ui.entry'] = function(ev, ...)
        local f = entry[ev]
        if f then
            f(...)
        else
            log.add('ui', 'unknown native event: %s', ev)
        end
    end,
    ['ui.draw'] = render,
}
for k, v in pairs(control.routes) do
    M.routes[k] = v
end

function M.activate(first)
    control.apply_config(HUB.state.config)
    if first then
        control.set_view(control.first_view())
    else
        control.ensure_usable_view()
    end
    control.check_prompts()
    make_layout()
    ncurses.clear()
    dispatch.dirty()
end

return M
