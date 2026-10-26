-- Terminal UI: layout, the draw function and the native entry points.
-- Only this layer touches ncurses.
--
-- Windows are handles, not data, so each generation makes its own when it
-- becomes current and on every resize.

local control   <const> = require 'hub.ui.control'
local matchdsl  <const> = require 'hub.lib.matchdsl'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'
local keymap    <const> = require 'hub.ui.keymap'
local statusbar <const> = require 'hub.ui.statusbar'
local dispatch  <const> = require 'hub.runtime.dispatch'
local log       <const> = require 'hub.runtime.log'
local tty       <const> = require 'hub.runtime.tty'

local M = {}

local pad_width <const> = keymap.pad_width

local layout = {textbox_offset = 0}

-- Click regions, rebuilt every frame: clicks[y] = {{lo, hi, action}, ...}
local clicks = {}

local function add_click(y, lo, hi, action)
    local list = clicks[y]
    local entry = {lo = lo, hi = hi, action = action}
    if list then
        table.insert(list, entry)
    else
        clicks[y] = {entry}
    end
end

local function add_button(win, text, action, plain)
    local y1, x1 = ncurses.getyx(win)
    if not plain then draw.reversevideo(win) end
    win:waddstr(text)
    if not plain then draw.reversevideo_(win) end
    local _, x2 = ncurses.getyx(win)
    add_click(y1, x1, x2, action)
end

local function make_layout()
    if layout.main_pad then layout.main_pad:delwin() end
    layout.main_pad = ncurses.newpad(tty_height - 1, pad_width)

    if layout.input_win then layout.input_win:delwin() end
    layout.input_win = ncurses.newwin(1, tty_width, tty_height - 1, 0)

    if layout.textbox_pad then layout.textbox_pad:delwin() end
    layout.textbox_pad = ncurses.newpad(1, 1024)
end

--- Context handed to a view's render, keypress and status functions.
local function view_context(view)
    return {
        id = view.id,
        vs = control.view_state(view.id),
        net = control.current_net(),
        rows = tty_height - 1,
        cols = tty_width,
        add_click = add_click,
        add_button = add_button,
    }
end

local function render()
    if tty.suspended() then return end

    clicks = {}
    local main_pad, input_win, textbox_pad = layout.main_pad, layout.input_win, layout.textbox_pad
    ncurses.erase()
    main_pad:werase()
    input_win:werase()
    textbox_pad:werase()

    local view = control.current_view()
    local ctx = view_context(view)

    draw.normal(main_pad)
    view.render(ctx, main_pad)

    statusbar.draw(input_win, textbox_pad, layout, view, ctx)

    local hscroll = math.max(0, math.min(ctx.vs.hscroll or 0, pad_width - tty_width))
    ncurses.noutrefresh()
    main_pad:pnoutrefresh(0, hscroll, 0, 0, tty_height - 2, tty_width - 1)
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

    -- the view gets a chance before the global keys; true consumes the key
    local view = control.current_view()
    if view.keypress and view.keypress(view_context(view), key) then
        return
    end

    local f = keymap.global[key]
    if f then f() end
end

function entry.on_paste(paste)
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
    for _, button in ipairs(clicks[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action(shifted)
            dispatch.dirty()
        end
    end
end

function entry.on_resize()
    make_layout()
    dispatch.dirty()
end

function entry.print(str)
    log.add('print', '%s', str)
end

-- Module interface ===================================================

M.init_state = control.init_state

M.views = {
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
}

M.commands = {
    {
        name = 'filter',
        spec = '$R',
        help = 'Show only lines of this view that match; no pattern clears it',
        fn = function(_, pattern)
            control.set_filter(HUB.state.ui.view, pattern)
        end,
    },
    {
        name = 'profile',
        spec = '$g',
        help = 'Switch the view rotation: dashboard, chat or all',
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
        help = 'Choose the network that views and commands act on',
        fn = function(_, id)
            control.set_current_net(id)
        end,
    },
}
for _, list in ipairs {
    require 'hub.ui.views.recent_conn',
    require 'hub.ui.views.server_load',
    require 'hub.ui.views.simple_load',
} do
    for _, view in ipairs(list) do
        table.insert(M.views, view)
    end
end

table.insert(M.commands, {
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
})

for _, view in ipairs(M.views) do
    if view.command == false then goto continue end
    table.insert(M.commands, {
        name = view.id,
        spec = '',
        help = 'Show the ' .. view.title .. ' view',
        fn = function() control.set_view(view.id) end,
    })
    ::continue::
end

function M.subscribe(sub)
    sub.on('task.prompt', control.add_prompt)
    sub.on('chat.focus', function(ev)
        control.set_current_net(ev.net)
        control.set_talk_target(ev.net, ev.target)
        control.set_view 'buffer'
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
        local rotation = control.rotation()
        control.set_view(rotation[1] or 'status')
    end
    control.check_prompts()
    make_layout()
    ncurses.clear()
    dispatch.dirty()
end

return M
