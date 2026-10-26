-- The bottom line: view name, input box or last log line (from ircc's
-- utils/drawing.lua draw_status_bar).

local addircstr <const> = require 'hub.ui.irc_formatting'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local editor    <const> = require 'hub.ui.editor'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'

local phase_palette <const> = {
    connected = ncurses.COLOR_GREEN,
    idle = ncurses.COLOR_RED,
}

-- Every network, coloured by phase (yellow while on the way), the current
-- one in reverse video; click one to make it current
local function draw_nets(win, ctx)
    local current = ctx.net
    for _, id in ipairs(control.net_ids()) do
        local rec = HUB.state.nets[id]
        win:waddstr ' '
        ncurses.colorset(phase_palette[rec.phase] or ncurses.COLOR_YELLOW, nil, win)
        if id == current then draw.reversevideo(win) end
        local _, x1 = ncurses.getyx(win)
        win:waddstr(scrub(id))
        local _, x2 = ncurses.getyx(win)
        if id == current then draw.reversevideo_(win) end
        ctx.add_click(tty_height - 1, x1, x2, function() control.set_current_net(id) end)
    end
    draw.normal(win)
end

local M = {}

local input_mode_palette <const> = {
    command = ncurses.COLOR_BLUE,
    talk = ncurses.COLOR_GREEN,
    filter = ncurses.COLOR_CYAN,
    password = ncurses.COLOR_RED,
}

--- Draw the status bar.
---@param win any window for the bar
---@param textbox any pad for the input text
---@param layout table shared with the renderer: textbox_offset is kept here
---@param ctx table view context of the current view
function M.draw(win, textbox, layout, view, ctx)
    local titlecolor = ncurses.COLOR_WHITE
    local input = HUB.state.ui.input
    local mode = input.mode

    ncurses.colorset(ncurses.COLOR_BLACK, titlecolor, win)
    win:wmove(0, 0)
    win:waddstr(string.format('%-8.8s', view.title or view.id))

    if mode then
        local ed = control.editor()
        local input_mode_color = input_mode_palette[mode]
        ncurses.colorset(titlecolor, input_mode_color, win)
        win:waddstr('')
        ncurses.colorset(ncurses.COLOR_WHITE, input_mode_color, win)
        win:waddstr(mode)
        ncurses.colorset(input_mode_color, nil, win)
        win:waddstr('')

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
        ncurses.colorset(titlecolor, nil, win)
        win:waddstr('')
        draw.normal(win)

        draw_nets(win, ctx)

        if view.status then
            view.status(ctx, win)
        end

        local last = HUB.state.log_last
        if last then
            addircstr(win, ' ' .. last)
        end

        if ctx.vs.scroll ~= 0 then
            win:waddstr(string.format(' SCROLL %d', ctx.vs.scroll))
        end

        if ctx.vs.filter then
            draw.yellow(win)
            win:waddstr ' FILTER '
            draw.normal(win)
            win:waddstr(scrub(string.format('%q', ctx.vs.filter)))
        end

        ctx.add_click(tty_height - 1, 0, 9, control.next_view)
        ncurses.cursset(0)
    end
end

return M
