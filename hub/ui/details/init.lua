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
-- limit. It may return a third, pinned(i): for the first row shown once
-- scrolled, a function that draws the row to keep above it (a table's
-- header), or nil. That row takes the pane's first row, over the rest.
--
-- A kind may also name the events that open it: `events` maps a topic to
-- a function of the event that returns the detail's net and data. Private
-- data doesn't come by event; it opens with dispatch.open_detail.
--
-- A kind that fails to draw is disabled until the next reload (disable_kind)
-- and the error logged as `origin` when the kind has one (a plugin's), else
-- as its name.

local clicks  <const> = require 'hub.ui.clicks'
local control <const> = require 'hub.ui.control'
local dispatch <const> = require 'hub.runtime.dispatch'
local draw    <const> = require 'hub.ui.draw'
local pads    <const> = require 'hub.ui.pads'
local log     <const> = require 'hub.runtime.log'
local scrub   <const> = require 'hub.lib.scrub'
local theme   <const> = require 'hub.ui.theme'

local M = {}

---@type table<string, table>
M.kinds = {}
for _, m in ipairs {
    require 'hub.ui.details.channel',
    require 'hub.ui.details.error',
    require 'hub.ui.details.format',
    require 'hub.ui.details.jump',
    require 'hub.ui.details.keys',
    require 'hub.ui.details.listing',
    require 'hub.ui.details.message',
    require 'hub.ui.details.reply',
    require 'hub.ui.details.value',
    require 'hub.ui.details.who',
    require 'hub.ui.details.whois',
    require 'hub.ui.details.whowas',
} do
    M.kinds[m.kind] = m
end

--- Disable a kind that failed to draw, as control.disable_view does a view.
---@param kind table
---@param err any
function M.disable_kind(kind, err)
    local name = kind.kind
    if M.kinds[name] ~= kind then return end -- disabled already
    M.kinds[name] = {kind = name, render = control.failed_render(name)}
    dispatch.dirty()
    dispatch.report(kind.origin or ('detail ' .. name), err)
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
        add_chip = clicks.chip,
        add_segments = clicks.segments,
        chip_gap = clicks.chip_gap,
    }
end

-- Text of tags, by columns
local function tags_width(tags)
    local n = 0
    for _, tag in ipairs(tags) do n = n + (utf8.len(tag[1]) or #tag[1]) end
    return n
end

-- The title cut to fit room columns
local function fit_title(title, room)
    room = math.max(1, room)
    if (utf8.len(title) or #title) > room then
        title = title:sub(1, (utf8.offset(title, room) or #title + 1) - 1) .. '…'
    end
    return title
end

local function draw_tags(pad, tags)
    for _, tag in ipairs(tags) do
        tag[2](pad)
        pad:waddstr(tag[1])
        draw.normal(pad)
    end
end

-- The log keeps what its lines open until they roll off; DISCARD lets it
-- go now
local function discard(detail)
    log.forget_detail(detail.data)
    control.close_detail()
end

--- The pane's rule on the classic theme, at the cursor: a line with
--- [CLOSE], ←BACK and [DISCARD], then the title, its tags and the scroll
--- position.
local function rule(pad, detail, title, tags, position)
    draw.normal(pad)
    pad:waddstr '─'
    clicks.chip(pad, 'CLOSE', control.close_detail)
    if control.can_go_back() then
        pad:waddstr '─'
        clicks.button(pad, '←BACK', control.back_detail, true)
    end
    if log.holds_detail(detail.data) then
        pad:waddstr '─'
        clicks.chip(pad, 'DISCARD', function() discard(detail) end)
    end
    pad:waddstr '─ '

    local _, title_x = ncurses.getyx(pad)
    title = fit_title(title, tty_width - title_x - tags_width(tags) - tags_width(position) - 1)
    draw.bold(pad)
    pad:waddstr(title)
    draw.bold_(pad)
    draw_tags(pad, tags)
    draw_tags(pad, position)
    pad:waddstr ' '
    local _, x = ncurses.getyx(pad)
    pad:waddstr(string.rep('─', math.max(0, tty_width - x)))
end

--- The pane's rule on the modern theme, at the cursor: a band of the
--- status bar's colors with ✕ (to close), ← (to go back) and the title
--- and its tags on the left, as a Mac window has them, and the scroll
--- position and DISCARD on the right.
local function band(pad, detail, title, tags, position)
    local surface, text = theme.surface()
    draw.set_base(pad, text, surface)
    draw.normal(pad)
    pad:waddstr ' '
    clicks.chip(pad, '✕', control.close_detail)
    pad:waddstr ' '
    if control.can_go_back() then
        clicks.button(pad, '←', control.back_detail, true)
        pad:waddstr ' '
    end

    local held = log.holds_detail(detail.data)
    local right = tags_width(position) + 1
    if held then right = right + clicks.chip_width 'DISCARD' + 1 end

    local _, title_x = ncurses.getyx(pad)
    title = fit_title(title, tty_width - title_x - tags_width(tags) - right - 1)
    draw.bold(pad)
    pad:waddstr(title)
    draw.bold_(pad)
    draw_tags(pad, tags)

    local _, x = ncurses.getyx(pad)
    pad:waddstr(string.rep(' ', math.max(1, tty_width - right - x)))
    draw_tags(pad, position)
    pad:waddstr ' '
    if held then
        clicks.chip(pad, 'DISCARD', function() discard(detail) end)
        pad:waddstr ' '
    end
    draw.set_base(pad)
    draw.normal(pad)
end

--- Render the detail pane into `pad`, for the top of the screen: its
--- content, up to half the screen and scrolled by the paging keys
--- (sideways too, for a `wide` kind, whose rows don't wrap), over a rule
--- (a band on the modern theme) with a close button, a back button when
--- it followed a click from what it showed, DISCARD when a log line holds
--- it, its title, its modes, its filter and the rows shown. Returns the rows it takes, and the
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
    local last -- the last content row shown
    if kind.rows then
        local draw_row, pinned
        used, draw_row, pinned = kind.rows(ctx)
        rows = math.min(used, limit)
        -- a pinned row leaves one fewer for the content, which scrolls on
        -- to show its last row under it
        if rows < 2 or used <= rows then pinned = nil end
        pads.set_paging(detail, used, pinned and rows - 1 or rows)
        top = detail.scroll
        local pin = pinned and top > 0 and pinned(top + 1)
        -- the rows shown, then the rule with a row to spare for the cursor
        -- after the last column
        local h, w = ncurses.getmaxyx(pad)
        if h ~= rows + 2 or w ~= width then pad:wresize(rows + 2, width) end
        clicks.restart()
        pad:werase()
        local y = 0
        if pin then
            pad:wmove(0, 0)
            draw.normal(pad)
            pin(pad)
            y = 1
        end
        last = top
        for i = top + 1, math.min(used, top + rows - y) do
            pad:wmove(y, 0)
            draw.normal(pad)
            draw_row(pad, i)
            y, last = y + 1, i
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

    -- the tags after the title, each text and its color, and the scroll
    -- position: the title is cut to leave them room on the screen
    local tags = {}
    if detail.net then table.insert(tags, {' ' .. detail.net, draw.cyan}) end
    for _, mode in ipairs(kind.modes and kind.modes(detail) or {}) do
        table.insert(tags, {' ' .. mode, draw.yellow})
    end
    local filter = kind.filter and control.filter 'detail'
    if filter then
        table.insert(tags, {' filter ', draw.yellow})
        table.insert(tags, {scrub(string.format('%q', filter)), draw.normal})
    end
    local position = {}
    if detail.max_scroll > 0 then
        table.insert(position, {string.format(' rows %d-%d of %d', top + 1, last or top + rows, used), draw.normal})
    end
    if hscroll > 0 then
        table.insert(position, {string.format(' cols +%d', hscroll), draw.normal})
    end
    local title = kind.title and kind.title(detail) or detail.kind

    -- the rule doesn't scroll sideways
    pad:wmove(rule_row, 0)
    if theme.surface() then
        band(pad, detail, title, tags, position)
    else
        rule(pad, detail, title, tags, position)
    end
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
