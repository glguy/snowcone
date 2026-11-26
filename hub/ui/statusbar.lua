-- The bottom line: view name, input box or last log line.

local addircstr <const> = require 'hub.ui.irc_formatting'
local cmdline   <const> = require 'hub.ui.cmdline'
local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'
local matching  <const> = require 'hub.lib.matching'
local oper      <const> = require 'hub.features.oper'
local scrub     <const> = require 'hub.lib.scrub'
local spell     <const> = require 'hub.runtime.spell'
local talk      <const> = require 'hub.ui.talk'
local theme     <const> = require 'hub.ui.theme'

local phase_palette <const> = {
    connected = ncurses.COLOR_GREEN,
    idle = ncurses.COLOR_RED,
}

local M = {}

--- Unseen chat on a network: 'mention' when a buffer with unseen
--- messages mentions us, 'activity' for unseen messages otherwise, nil
--- when all is seen.
---@param net string
---@return 'mention'|'activity'|nil
function M.activity(net)
    local C = common.get_state('chat', net)
    local seen
    for _, buffer in pairs(C and C.buffers or {}) do
        if buffer.mention and buffer.activity > 0 then return 'mention' end
        if buffer.activity > 0 then seen = 'activity' end
    end
    return seen
end

-- The separator between fragments of the bar, and its line version for
-- fragments that share a background, by ui.separators (ui/theme.lua): set
-- at each draw
M.separator = theme.glyph_sets.powerline.right
M.thin_separator = theme.glyph_sets.powerline.right_thin

-- Background color of the fragment being drawn (nil for the terminal's),
-- and the band's, with the color of text on it: the background of a
-- fragment that has none of its own (nil without a band)
local background
local surface, surface_text

--- Make bg the background the bar's text is drawn on: the window's base
--- (draw.set_base), so views' colors keep it.
local function set_background(win, bg)
    background = bg
    draw.set_base(win, bg == surface and surface_text or nil, bg)
end

--- Draw the separator from a region on background `from` into one on `to`
--- (nil for the terminal's): a triangle in the old background on the new
--- one, so the colors stay connected, or the line when they are the same.
local function transition(win, from, to)
    draw.set_base(win)
    draw.normal(win)
    if from == to then
        ncurses.colorset(to == surface and surface_text or ncurses.COLOR_WHITE, to, win)
        win:waddstr(M.thin_separator)
    elseif from then
        ncurses.colorset(from, to, win)
        win:waddstr(M.separator)
    else
        -- the terminal's background has no color number to draw in, but
        -- reverse video paints the triangle with it
        ncurses.colorset(to, nil, win)
        draw.reversevideo(win)
        win:waddstr(M.separator)
    end
    set_background(win, to)
    draw.normal(win)
end

--- Start a new fragment of the status bar on background `bg` (the band's
--- when not given), padded on either side of the separator by a space in
--- the background of the fragment it belongs to.
---@param win ncurses.Window
---@param bg integer|nil
function M.fragment(win, bg)
    bg = bg or surface
    draw.normal(win)
    win:waddstr ' '
    transition(win, background, bg)
    win:waddstr ' '
end

-- Every network not shelved, and the current one, as a region of its own,
-- colored by phase (yellow while on the way): the current one on a
-- background of that color, so the bar's colors run through it. The first follows straight on from the title.
-- Click one to make it current.
local function draw_nets(win, ctx, titlecolor)
    local current = ctx.net
    local first = true
    for _, id in ipairs(control.bar_net_ids()) do
        local rec = HUB.state.nets[id]
        local color = phase_palette[rec.phase] or ncurses.COLOR_YELLOW
        local bg = id == current and color or surface
        if first then
            transition(win, titlecolor, bg)
            win:waddstr ' '
            first = false
        else
            M.fragment(win, bg)
        end

        local lit = id == current
        if lit then
            ncurses.colorset(ncurses.COLOR_BLACK, bg, win)
        else
            ncurses.colorset(color, bg, win)
        end
        local _, x1 = ncurses.getyx(win)
        win:waddstr(scrub(id))
        local _, x2 = ncurses.getyx(win)
        ctx.add_click(tty_height - 1, x1, x2, function() control.set_current_net(id) end)

        -- unseen chat: ! for a mention, + otherwise (in black on the
        -- current network, where the colors would vanish)
        local marker = M.activity(id)
        if marker then
            if lit then
                ncurses.colorset(ncurses.COLOR_BLACK, bg, win)
                draw.bold(win)
            else
                ncurses.colorset(marker == 'mention' and ncurses.COLOR_MAGENTA or ncurses.COLOR_YELLOW, bg, win)
            end
            win:waddstr(marker == 'mention' and '!' or '+')
        end
    end
    if first then
        transition(win, titlecolor, surface)
    end
    draw.normal(win)
end

local input_mode_palette <const> = {
    command = ncurses.COLOR_BLUE,
    talk = ncurses.COLOR_GREEN,
    quiet = ncurses.COLOR_GREEN,
    action = ncurses.COLOR_MAGENTA,
    notice = ncurses.COLOR_YELLOW,
    filter = ncurses.COLOR_CYAN,
    password = ncurses.COLOR_RED,
}

--- Draw the active modes of the view, as one fragment of lower-case tags
--- in yellow, each with its value (if any) in the normal color: the
--- view's own (from view.modes) and then the scroll and filter every view
--- has. Nothing when no mode is on.
local function draw_modes(win, view, ctx)
    local vs = ctx.vs
    local modes = view.modes and control.attempt(control.disable_view, view, view.modes, ctx) or {}

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

--- Color behind the view title: red while a K-Line is staged on the
--- current network, so it is hard to miss.
function M.title_color()
    local net = control.current_net()
    if net and common.enabled(net, 'oper') then
        local staged = oper.get(net).staged
        if staged and staged.action == 'kline' then
            return ncurses.COLOR_RED
        end
    end
    return ncurses.COLOR_WHITE
end

-- The misspelled words of the line being talked on net, but for names
-- where it goes, and, while typing, the word at the cursor
---@param net string
---@param ed hub.Editor
local function misspelled(net, ed)
    if not spell.available() then return nil end
    local typing = (ed.state == 'insert' or ed.state == 'erase') and #ed.before_cursor + 1 or nil
    return spell.misspelled_ranges(ed.before_cursor .. ed.at_cursor, talk.names_here(net), typing)
end

-- The bar between a command's arguments
local argument_bar <const> = '│'

--- Draw a command line being typed as ui/cmdline sees it: its command,
--- arguments and message text, then the placeholders of the arguments not
--- yet typed. Returns the cursor's column.
---@param win ncurses.Window
---@param ed hub.Editor
---@param color integer the input mode's color, for text as typed
---@return integer
local function draw_command(win, ed, color)
    local text = ed.before_cursor .. ed.at_cursor
    local cursor = #ed.before_cursor
    local look = cmdline.decorate(text, cursor)
    local _, back = draw.base(win)
    local muted = theme.text 'muted'
    local cursor_x

    local function set(role)
        draw.normal(win)
        if role == 'good' or role == 'warn' or role == 'bad' then
            ncurses.colorset(theme.command(role), back, win)
        elseif role == 'sep' or role == 'ghost' then
            ncurses.colorset(muted or color, back, win)
            if not muted then draw.dim(win) end
        else
            ncurses.colorset(color, back, win)
        end
    end
    local function here()
        cursor_x = cursor_x or select(2, ncurses.getyx(win))
    end
    -- bytes lo to hi of the line, noting the cursor's column among them
    local function put(lo, hi)
        if cursor >= lo - 1 and cursor < hi then
            win:waddstr(scrub(text:sub(lo, cursor)))
            here()
            win:waddstr(scrub(text:sub(cursor + 1, hi)))
        else
            win:waddstr(scrub(text:sub(lo, hi)))
        end
    end

    for _, s in ipairs(look.spans) do
        if s.role == 'text' then
            -- as it will be seen, codes and all, and spell checked
            local sub = text:sub(s.lo, s.hi)
            local inside = cursor >= s.lo - 1 and cursor <= s.hi
            local typing = (ed.state == 'insert' or ed.state == 'erase') and cursor + 2 - s.lo or nil
            local bad = look.net and spell.available()
                and spell.misspelled_ranges(sub, talk.names_here(look.net), typing) or nil
            local x = addircstr(win, sub, {mark = inside and cursor - s.lo + 1 or -1, color = color, bad = bad})
            if inside then cursor_x = cursor_x or x end
        elseif s.role == 'sep' then
            set 'sep'
            if cursor == s.lo - 1 then here() end
            win:waddstr(argument_bar)
            put(s.lo + 1, s.hi)
        else
            set(s.role)
            put(s.lo, s.hi)
        end
    end
    here()

    for i, ghost in ipairs(look.ghosts) do
        set 'ghost'
        if i > 1 or look.ghost_sep then win:waddstr(argument_bar) end
        if ghost.optional then draw.italic(win) end
        win:waddstr(scrub(ghost.label), ghost.repeats and '…' or '')
    end
    draw.normal(win)
    ---@cast cursor_x integer
    return cursor_x
end

--- Draw the status bar.
---@param win ncurses.Window for the bar
---@param textbox ncurses.Window pad for the input text
---@param layout {textbox_offset: integer} shared with the renderer: the bar
--- keeps textbox_offset here
---@param view table the current view
---@param ctx hub.ViewContext of the current view
function M.draw(win, textbox, layout, view, ctx)
    local glyphs = theme.glyphs()
    M.separator, M.thin_separator = glyphs.right, glyphs.right_thin
    surface, surface_text = theme.surface()
    set_background(win, nil)

    local titlecolor = M.title_color()
    local input = HUB.state.ui.input
    local mode = input.mode

    ncurses.colorset(ncurses.COLOR_BLACK, titlecolor, win)
    win:wmove(0, 0)
    win:waddstr(string.format('%-8.8s', view.title or view.id))

    if mode then
        local ed = control.editor()
        local input_mode_color = input_mode_palette[mode]
        transition(win, titlecolor, input_mode_color)
        -- padded on either side, as M.fragment pads a fragment; talking
        -- behind a STATUSMSG prefix shows it, and a line too long to send
        -- shows by how much, for when its cut is scrolled out of the
        -- input line
        ncurses.colorset(ncurses.COLOR_WHITE, input_mode_color, win)
        local net = talk.modes[mode] and control.current_net()
        local prefix = net and talk.statusmsg(net)
        local cut, over
        if net then
            cut, over = talk.overflow(net, mode, ed.before_cursor .. ed.at_cursor)
        end
        win:waddstr(' ', mode, ' ', prefix and prefix .. ' ' or '', over and '-' .. over .. ' ' or '')
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

        local _, x0 = ncurses.getyx(win)
        textbox:wmove(0, 0)
        local x1
        if mode == 'filter' then
            -- a pattern, in green when it compiles
            if matching.compile(editor.content(ed)) then
                draw.green(textbox)
            else
                draw.red(textbox)
            end
            textbox:waddstr(scrub(ed.before_cursor))
            x1 = select(2, ncurses.getyx(textbox))
            textbox:waddstr(scrub(ed.at_cursor))
        elseif mode == 'command' then
            x1 = draw_command(textbox, ed, input_mode_color)
        else
            -- formatted as it will be seen, codes and all
            x1 = addircstr(textbox, ed.before_cursor .. ed.at_cursor,
                {mark = #ed.before_cursor, color = input_mode_color, cut = cut,
                 bad = net and misspelled(net, ed)})
        end
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
            control.attempt(control.disable_view, view, view.status, ctx, win)
        end
        draw_modes(win, view, ctx)

        local last = HUB.state.log_last
        if last then
            M.fragment(win)
            addircstr(win, last)
        end

        -- the band runs to the end of the row; without one, a colored
        -- last fragment closes onto the terminal's background
        if surface then
            if background ~= surface then M.fragment(win) end
            draw.normal(win)
            local _, x = ncurses.getyx(win)
            win:waddstr(string.rep(' ', math.max(0, tty_width - x)))
        elseif background then
            M.fragment(win, nil)
        end

        ctx.add_click(tty_height - 1, 0, 9, control.next_view)
        ncurses.cursset(0)
    end
end

return M
