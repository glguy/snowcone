-- The bottom line: view name, input box or last log line.

local addircstr <const> = require 'hub.ui.irc_formatting'
local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'
local matching  <const> = require 'hub.lib.matching'
local oper      <const> = require 'hub.features.oper'
local scrub     <const> = require 'hub.lib.scrub'

local phase_palette <const> = {
    connected = ncurses.COLOR_GREEN,
    idle = ncurses.COLOR_RED,
}

local function activity(net)
    local C = common.get_state('chat', net)
    local seen
    for _, buffer in pairs(C and C.buffers or {}) do
        if buffer.mention and buffer.activity > 0 then return 'mention' end
        if buffer.activity > 0 then seen = 'activity' end
    end
    return seen
end

local M = {}

-- The separator between fragments of the bar (a Powerline triangle), and
-- its line version for fragments that share a background
M.separator = utf8.char(0xE0B0)
M.thin_separator = utf8.char(0xE0B1)

-- Background colour of the fragment being drawn (nil for the terminal's)
local background

--- Draw the separator from a region on background `from` into one on `to`
--- (nil for the terminal's): a triangle in the old background on the new
--- one, so the colours stay connected, or the line when they are the same.
local function transition(win, from, to)
    draw.normal(win)
    if from == to then
        ncurses.colorset(ncurses.COLOR_WHITE, to, win)
        win:waddstr(M.thin_separator)
    elseif from then
        ncurses.colorset(from, to, win)
        win:waddstr(M.separator)
    else
        -- the terminal's background has no colour number to draw in, but
        -- reverse video paints the triangle with it
        ncurses.colorset(to, nil, win)
        draw.reversevideo(win)
        win:waddstr(M.separator)
    end
    draw.normal(win)
    background = to
end

--- Start a new fragment of the status bar on background `bg` (nil for the
--- terminal's), padded on either side of the separator by a space in the
--- background of the fragment it belongs to.
function M.fragment(win, bg)
    draw.normal(win)
    ncurses.colorset(nil, background, win)
    win:waddstr ' '
    transition(win, background, bg)
    ncurses.colorset(nil, bg, win)
    win:waddstr ' '
end

-- Every network as a region of its own, coloured by phase (yellow while on
-- the way): the current one on a background of that colour, so the bar's
-- colours run through it. The first follows straight on from the title.
-- Click one to make it current.
local function draw_nets(win, ctx, titlecolor)
    local current = ctx.net
    local first = true
    for _, id in ipairs(control.net_ids()) do
        local rec = HUB.state.nets[id]
        local colour = phase_palette[rec.phase] or ncurses.COLOR_YELLOW
        local bg = id == current and colour or nil
        if first then
            transition(win, titlecolor, bg)
            ncurses.colorset(nil, bg, win)
            win:waddstr ' '
            first = false
        else
            M.fragment(win, bg)
        end

        if bg then
            ncurses.colorset(ncurses.COLOR_BLACK, bg, win)
        else
            ncurses.colorset(colour, nil, win)
        end
        local _, x1 = ncurses.getyx(win)
        win:waddstr(scrub(id))
        local _, x2 = ncurses.getyx(win)
        ctx.add_click(tty_height - 1, x1, x2, function() control.set_current_net(id) end)

        -- unseen chat: ! for a mention, + otherwise (in black on the
        -- current network, where the colours would vanish)
        local marker = activity(id)
        if marker then
            if bg then
                ncurses.colorset(ncurses.COLOR_BLACK, bg, win)
                draw.bold(win)
            else
                ncurses.colorset(marker == 'mention' and ncurses.COLOR_MAGENTA or ncurses.COLOR_YELLOW, nil, win)
            end
            win:waddstr(marker == 'mention' and '!' or '+')
        end
    end
    if first then
        transition(win, titlecolor, nil)
    end
    draw.normal(win)
end

local input_mode_palette <const> = {
    command = ncurses.COLOR_BLUE,
    talk = ncurses.COLOR_GREEN,
    filter = ncurses.COLOR_CYAN,
    password = ncurses.COLOR_RED,
}

--- Draw the active modes of the view, as one fragment of lower-case tags
--- in yellow, each with its value (if any) in the normal colour: the
--- view's own (from view.modes) and then the scroll and filter every view
--- has. Nothing when no mode is on.
local function draw_modes(win, view, ctx)
    local vs = ctx.vs
    local modes = view.modes and view.modes(ctx) or {}

    -- once scrolled, a document shows how far down it is
    local rows
    if vs.scroll ~= 0 then
        rows = view.document and string.format('%d/%d', vs.scroll, vs.max_scroll or 0)
            or tostring(vs.scroll)
    end
    if (vs.hscroll or 0) > 0 then
        table.insert(modes, {'scroll', string.format('%s,+%d', rows or '0', vs.hscroll)})
    elseif rows then
        table.insert(modes, {'scroll', rows})
    end

    if vs.filter then
        table.insert(modes, {'filter', scrub(string.format('%q', vs.filter))})
    end

    if #modes == 0 then return end
    M.fragment(win)
    for i, mode in ipairs(modes) do
        if i > 1 then win:waddstr ' ' end
        draw.yellow(win)
        if type(mode) == 'table' then
            win:waddstr(mode[1])
            draw.normal(win)
            win:waddstr(' ', mode[2])
        else
            win:waddstr(mode)
        end
    end
    draw.normal(win)
end

--- Colour behind the view title: red while a K-Line is staged on the
--- current network, so it is hard to miss.
function M.title_colour()
    local net = control.current_net()
    if net and common.enabled(net, 'oper') then
        local staged = oper.get(net).staged
        if staged and staged.action == 'kline' then
            return ncurses.COLOR_RED
        end
    end
    return ncurses.COLOR_WHITE
end

--- Draw the status bar.
---@param win any window for the bar
---@param textbox any pad for the input text
---@param layout table shared with the renderer: textbox_offset is kept here
---@param ctx table view context of the current view
function M.draw(win, textbox, layout, view, ctx)
    local titlecolor = M.title_colour()
    local input = HUB.state.ui.input
    local mode = input.mode

    ncurses.colorset(ncurses.COLOR_BLACK, titlecolor, win)
    win:wmove(0, 0)
    win:waddstr(string.format('%-8.8s', view.title or view.id))

    if mode then
        local ed = control.editor()
        local input_mode_color = input_mode_palette[mode]
        transition(win, titlecolor, input_mode_color)
        -- padded on either side, as M.fragment pads a fragment
        ncurses.colorset(ncurses.COLOR_WHITE, input_mode_color, win)
        win:waddstr(' ', mode, ' ')
        transition(win, input_mode_color, nil)

        if mode == 'password' then
            local n <const> = editor.size(ed)
            local spinner <const> = {'◇◇◇', '◆◇◇', '◆◆◇', '◆◆◆', '◇◆◆', '◇◇◆'}
            draw.bold(win)
            local prompt = control.current_prompt() or {}
            local label = (prompt.net and prompt.net .. ': ' or '') .. (prompt.label or '')
            win:waddstr(' ', scrub(label), ' ', spinner[n % #spinner + 1])
            ncurses.cursset(0)
            return
        end

        ncurses.colorset(input_mode_color, nil, textbox)
        if mode == 'filter' then
            if matching.compile(editor.content(ed)) then
                draw.green(textbox)
            else
                draw.red(textbox)
            end
        end

        local _, x0 = ncurses.getyx(win)
        textbox:wmove(0, 0)
        textbox:waddstr(scrub(ed.before_cursor))
        local _, x1 = ncurses.getyx(textbox)
        textbox:waddstr(scrub(ed.at_cursor))
        textbox:wmove(0, x1)
        ncurses.cursset(1)

        local width = tty_width - x0
        local offset = layout.textbox_offset

        -- cursor would exceed the right side of the terminal
        if x1 - width + 1 >= offset then
            offset = x1 - width + 8
        end

        -- cursor would exceed the left side of the terminal
        if x1 < offset then
            offset = math.max(0, x1 - 8)
        end
        layout.textbox_offset = offset

        if offset > 0 then
            draw.yellow(win)
            win:waddstr('…')
        else
            win:waddstr(' ')
        end
    else
        draw_nets(win, ctx, titlecolor)

        -- views start each fragment of their own with ctx.fragment
        ctx.fragment = M.fragment
        if view.status then
            view.status(ctx, win)
        end
        draw_modes(win, view, ctx)

        local last = HUB.state.log_last
        if last then
            M.fragment(win)
            addircstr(win, last)
        end

        -- close a coloured last fragment onto the terminal's background
        if background then
            M.fragment(win, nil)
        end

        ctx.add_click(tty_height - 1, 0, 9, control.next_view)
        ncurses.cursset(0)
    end
end

return M
