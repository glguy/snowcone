-- The renderers of the detail pane, by kind, where the filter goes, and
-- the pane's frame: its content scrolled to fit, over the rule.
--
-- A renderer is {kind, render(ctx, win), title(detail), modes(detail),
-- keypress(ctx, key), filter, wide}; ctx.vs is the detail record. One with
-- `filter` set takes the filter (Ctrl-S, /filter) while it is shown, and
-- reads it with control.filter(ctx.id), as a view does. A `wide` one draws
-- rows that don't wrap, which Left and Right scroll; the rest wrap at the
-- terminal's width (ctx.cols), as document views do.
--
-- A wide kind whose content can be long has rows(ctx) in place of render:
-- it returns how many rows there are and a function draw(win, i) of the
-- row i, drawn at the cursor, at the start of an empty row; only the rows
-- shown are drawn, so the content costs nothing past them and has no
-- limit.
--
-- A kind may also name the events that open it: `events` maps a topic to
-- a function of the event that returns the detail's net and data. Private
-- data doesn't come by event; it opens with the ui.open_detail route.

local clicks  <const> = require 'hub.ui.clicks'
local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local pads    <const> = require 'hub.ui.pads'
local log     <const> = require 'hub.runtime.log'
local scrub   <const> = require 'hub.lib.scrub'

local M = {}

---@type table<string, table>
M.kinds = {}
for _, m in ipairs {
    require 'hub.ui.details.channel',
    require 'hub.ui.details.error',
    require 'hub.ui.details.keys',
    require 'hub.ui.details.message',
    require 'hub.ui.details.reply',
    require 'hub.ui.details.value',
    require 'hub.ui.details.whois',
    require 'hub.ui.details.whowas',
} do
    M.kinds[m.kind] = m
end

--- What a filter applies to now: 'detail' while the pane shows a kind
--- that filters, else the current view's id.
---@return string
function M.filter_target()
    local detail = control.detail()
    local kind = detail and M.kinds[detail.kind]
    if kind and kind.filter then return 'detail' end
    return HUB.state.ui.view
end

-- The pane's frame ===================================================

local pad_width <const> = pads.width

--- A detail renderer gets the detail as its view state, and the pane's
--- rows.
---@param detail hub.Detail
---@param rows integer
---@return hub.ViewContext
function M.context(detail, rows)
    return {
        id = 'detail',
        vs = detail,
        net = detail.net,
        rows = rows,
        cols = tty_width,
        add_click = clicks.add,
        add_button = clicks.button,
    }
end

--- Render the detail pane into `pad`, for the top of the screen: its
--- content, up to half the screen and scrolled by the paging keys
--- (sideways too, for a `wide` kind, whose rows don't wrap), over a rule
--- with [CLOSE], [DISCARD] when a log line holds it, its title, its modes,
--- its filter and the rows shown. Returns the rows it takes, and the
--- refresh to do.
---@param detail hub.Detail
---@param kind table its renderer
---@param pad ncurses.Window
---@return integer rows
---@return fun()|nil refresh
function M.render(detail, kind, pad)
    local limit = (tty_height - 1) // 2 - 1
    if limit < 1 then return 0 end -- no room

    local ctx = M.context(detail, limit)
    local width = kind.wide and pad_width or tty_width
    local hscroll = kind.wide and math.max(0, math.min(detail.hscroll or 0, pad_width - tty_width)) or 0
    detail.hscroll = hscroll

    -- used counts the content's rows; the pad holds them from pad_top,
    -- and the rule goes on its row rule_row
    local used, rows, top, pad_top, rule_row
    if kind.rows then
        local draw_row
        used, draw_row = kind.rows(ctx)
        rows = math.min(used, limit)
        pads.set_paging(detail, used, rows)
        top = detail.scroll
        -- the rows shown, then the rule with a row to spare for the cursor
        -- after the last column
        local h, w = ncurses.getmaxyx(pad)
        if h ~= rows + 2 or w ~= width then pad:wresize(rows + 2, width) end
        clicks.restart()
        pad:werase()
        for i = 1, rows do
            pad:wmove(i - 1, 0)
            draw.normal(pad)
            draw_row(pad, top + i)
        end
        pad_top, rule_row = 0, rows
    else
        used = pads.draw_grown(pad, width, function(win) kind.render(ctx, win) end)
        rows = math.min(used, limit)
        pads.set_paging(detail, used, rows)
        top = detail.scroll
        -- the rule goes on the row after the content, with a row to spare
        -- for the cursor after the last column
        if ncurses.getmaxyx(pad) < used + 2 then
            pad:wresize(used + 2, width)
        end
        pad_top, rule_row = top, used
    end
    clicks.place(pad_top, rows, 0, hscroll)

    -- the rule doesn't scroll sideways
    pad:wmove(rule_row, 0)
    draw.normal(pad)
    pad:waddstr '─'
    clicks.button(pad, '[CLOSE]', control.close_detail)
    -- the log keeps what its lines open until they roll off; this lets it
    -- go now
    if log.holds_detail(detail.data) then
        pad:waddstr '─'
        clicks.button(pad, '[DISCARD]', function()
            log.forget_detail(detail.data)
            control.close_detail()
        end)
    end
    pad:waddstr '─ '
    draw.bold(pad)
    pad:waddstr(kind.title and kind.title(detail) or detail.kind)
    draw.bold_(pad)
    if detail.net then
        draw.cyan(pad)
        pad:waddstr(' ', detail.net)
        draw.normal(pad)
    end
    for _, mode in ipairs(kind.modes and kind.modes(detail) or {}) do
        draw.yellow(pad)
        pad:waddstr(' ', mode)
        draw.normal(pad)
    end
    local filter = kind.filter and control.filter 'detail'
    if filter then
        draw.yellow(pad)
        pad:waddstr ' filter '
        draw.normal(pad)
        pad:waddstr(scrub(string.format('%q', filter)))
    end
    if detail.max_scroll > 0 then
        pad:waddstr(string.format(' rows %d-%d of %d', top + 1, top + rows, used))
    end
    if hscroll > 0 then
        pad:waddstr(string.format(' cols +%d', hscroll))
    end
    pad:waddstr ' '
    local _, x = ncurses.getyx(pad)
    pad:waddstr(string.rep('─', math.max(0, tty_width - x)))
    clicks.place(rule_row, 1, rows)

    return rows + 1, function()
        if rows > 0 then
            pad:pnoutrefresh(pad_top, hscroll, 0, 0, rows - 1, tty_width - 1)
        end
        pad:pnoutrefresh(rule_row, 0, rows, 0, rows, tty_width - 1)
    end
end

-- Events =============================================================

--- Open each kind on the events it names.
---@param sub {on: fun(topic: string, fn: fun(ev: table))}
function M.subscribe(sub)
    for kind, m in pairs(M.kinds) do
        for topic, open in pairs(m.events or {}) do
            sub.on(topic, function(ev)
                control.open_detail(kind, open(ev))
            end)
        end
    end
end

return M
