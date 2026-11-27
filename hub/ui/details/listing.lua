-- A listing (hub.Listing, features/queries/listing.lua) in the detail
-- pane: the errors the server gave, then a table (ui/table.lua) per kind
-- of reply, in the order they first came, each under its numeric and how
-- many there are. M.runs draws any replies so, as a /quote's table view
-- does (ui/details/reply.lua).
--
-- A table's columns are the reply's fields as the network names them
-- (net/replies/solanum.lua or hybrid.lua), its values read for what they
-- mean: times as dates, seconds and minutes as durations, ban types by
-- name, a reason apart from its oper reason, an address the server won't
-- give as "-". A reply the network has a reader for (net/replies/read.lua:
-- auth blocks, links, modules) has the columns of what the reader makes
-- of it. A reply the network doesn't name the fields of is one column of
-- text: its arguments, after our nick for a numeric. A listing of lines
-- (hub.ListingLines) is one table of their text, whatever replies hold
-- them.
--
-- The rows, their cells and the tables are worked out once and kept on
-- the listing, for its list of messages: a STATS can have tens of
-- thousands of rows, and only those shown are drawn. The filter (Ctrl-S,
-- /filter) shows the rows with a cell that matches. Click a column's
-- header to sort its table by it.

local address_key <const> = require 'hub.lib.address_key'
local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local ircd    <const> = require 'hub.net.ircd'
local read    <const> = require 'hub.net.replies.read'
local replies <const> = require 'hub.net.replies'
local scrub   <const> = require 'hub.lib.scrub'
local tables  <const> = require 'hub.ui.table'

local M = {kind = 'listing', filter = true, wide = true}

M.events = {
    ['query.listing'] = function(ev) return ev.net, ev.listing end,
}

function M.title(detail)
    ---@type hub.Listing
    local l = detail.data
    local n = #l.messages
    return string.format('%s (%d %s)', scrub(l.command), n, n == 1 and 'reply' or 'replies')
end

-- Cells ==============================================================

-- A column whose cells are the i-th of a row's, sorted by the i-th of its
-- keys when it has one
local function column(i, header, formatted, optional)
    return {header = header, text = function(cells) return cells[i] end,
        key = function(cells) return cells.keys and cells.keys[i] end,
        formatted = formatted, optional = optional}
end

local function nonempty(value)
    if value ~= nil and value ~= '' then return value end
end

-- What a value of a field's kind sorts by, nil to sort as text
local function key_of(kind, value)
    if kind == 'addr' then
        local addr = replies.address(value)
        return addr and address_key(addr)
    end
    local n = tonumber(value)
    if kind == 'time' or kind == 'secs' then return n end
    -- 0 is permanent, which lasts longest
    if kind == 'mins' then return n == 0 and math.huge or n end
end

-- A value of a field's kind, as its cell shows it
local function cell_of(meant, kind, value)
    local n = tonumber(value)
    if kind == 'time' and n then return draw.date('%Y-%m-%d %H:%M', n) end
    if kind == 'secs' and n then return draw.duration(n) end
    if kind == 'mins' and n then return n == 0 and 'permanent' or draw.duration(n * 60) end
    if kind == 'line' then return meant.line_types[value] or value end
    if kind == 'addr' then return replies.address(value) end
    return value
end

--- The columns of a reply with fields, and its cells.
---@return table[] columns
---@return fun(msg: hub.Message): table cells
local function by_fields(meant, fields, relabel)
    local columns = {}
    for _, spec in ipairs(fields) do
        local label, kind = spec:match '^(.-):(%a+)$'
        label = label or spec
        if label ~= '-' then
            label = relabel and relabel[label] or label
            local formatted = kind == 'text' or kind == 'reasons'
            table.insert(columns, column(#columns + 1, label, formatted))
            if kind == 'reasons' then
                table.insert(columns, column(#columns + 1, 'oper reason', true, true))
            end
        end
    end
    local more = #columns + 1
    table.insert(columns, column(more, 'more', false, true))

    return columns, function(msg)
        local cells, c, i = {}, 1, 2
        for k, spec in ipairs(fields) do
            local label, kind = spec:match '^(.-):(%a+)$'
            label = label or spec
            local value
            if kind == 'rest' then
                -- leave one argument for each field after this one
                local last = #msg - (#fields - k)
                value = last >= i and table.concat(msg, ' ', i, last) or nil
                i = math.max(i, last + 1)
            else
                value = msg[i]
                i = i + 1
            end
            if label ~= '-' then
                value = nonempty(value)
                if kind == 'reasons' then
                    -- "reason|oper reason"; hybrid puts spaces about the |
                    local public, private = (value or ''):match '^(.-)%s*|%s*(.*)$'
                    if public then
                        cells[c], cells[c + 1] = nonempty(public), nonempty(private)
                    else
                        cells[c] = value
                    end
                    c = c + 2
                else
                    cells[c] = value and cell_of(meant, kind, value)
                    local sort_key = value and key_of(kind, value)
                    if sort_key then
                        cells.keys = cells.keys or {}
                        cells.keys[c] = sort_key
                    end
                    c = c + 1
                end
            end
        end
        if i <= #msg then cells[more] = table.concat(msg, ' ', i) end
        return cells
    end
end

-- The columns of the replies a network reads (net/replies/read.lua), by
-- reader, and their cells from what the reader makes of a reply
local read_columns <const> = {}

read_columns[read.auth_block] = function()
    return {
        column(1, 'mask'), column(2, 'flags', false, true), column(3, 'class'),
        column(4, 'spoof or redirect', false, true), column(5, 'port', false, true),
        column(6, 'password', false, true), column(7, 'description', true, true),
    }, function(b)
        ---@cast b hub.AuthBlock
        local names = {}
        for _, flag in ipairs(b.flags) do table.insert(names, flag[2]) end
        return {
            b.user .. '@' .. (b.hidden and '(hidden)' or b.host or '?'),
            names[1] and table.concat(names, ','),
            b.class,
            nonempty(b.spoof or b.redirect),
            b.redirect_port,
            b.password,
            nonempty(b.description),
        }
    end
end

read_columns[read.link] = function()
    return {
        column(1, 'link'), column(2, 'sendq'), column(3, 'sent msgs'), column(4, 'sent KiB'),
        column(5, 'recv msgs'), column(6, 'recv KiB'), column(7, 'open'), column(8, 'idle'),
        column(9, 'caps', false, true),
    }, function(k)
        ---@cast k hub.Link
        return {
            k.name, k.sendq, k.sent_msgs, k.sent_kib, k.recv_msgs, k.recv_kib,
            k.open and draw.duration(k.open) or nonempty(k.times),
            k.idle and draw.duration(k.idle),
            k.caps,
            keys = {[7] = k.open, [8] = k.idle},
        }
    end
end

-- the address sorts as a number
read_columns[read.module] = function()
    return {
        column(1, 'module'), column(2, 'origin'), column(3, 'core', false, true),
        column(4, 'version', true, true), column(5, 'description', true, true),
        column(6, 'address', false, true),
    }, function(m)
        ---@cast m hub.Module
        return {
            m.name, m.origin, m.core and 'core' or nil, nonempty(m.version), nonempty(m.description), m.address,
            keys = {[6] = m.address and math.tointeger(tonumber(m.address))},
        }
    end
end

-- A reply the network names no fields of: its arguments as text
local function plain(first)
    return {column(1, 'text', true)}, function(msg)
        return {nonempty(table.concat(msg, ' ', first))}
    end
end

-- Sections ===========================================================

-- Changes with every load, so a listing kept across a reload is laid out
-- again by the code loaded
local version <const> = {}

-- The text of a reply as lines show it: a row for each
---@param lines hub.ListingLines
---@param msg hub.Message
---@return string[]
local function line_texts(lines, msg)
    local text = msg[#msg] or ''
    if lines.strip then text = text:gsub(lines.strip, '', 1) end
    if not lines.words then return {text} end
    local words = {}
    for word in text:gmatch '%S+' do table.insert(words, word) end
    return words
end

--- The sections of messages, worked out once and kept on holder for
--- those messages: {numeric, name, columns, rows}, a row the cells of a
--- reply.
---@param net string|nil
---@param holder table
---@param messages hub.Message[]
---@param relabel table<string, string>|nil
---@param lines hub.ListingLines|nil every reply as lines of text
local function sections_of(net, holder, messages, relabel, lines)
    local view = holder.view
    if view and view.version == version and view.messages == messages then return view.sections end
    -- what the tables were sorted by stays
    local sorts = {}
    for _, section in ipairs(view and view.sections or {}) do
        sorts[section.command] = section.sort
    end
    local meant = replies.of(net)
    local sections, by_command = {}, {}
    for _, msg in ipairs(messages) do
        local n = lines and lines.under or msg.command
        local section = by_command[n]
        if not section then
            local reader = meant.readers[n]
            local columns, convert
            if lines then
                columns = {column(1, lines.column or 'text', true)}
            elseif reader and read_columns[reader] then
                local cells
                columns, cells = read_columns[reader]()
                convert = function(m) return cells(reader(meant, m)) end
            elseif meant.fields[n] then
                columns, convert = by_fields(meant, meant.fields[n], relabel)
            else
                columns, convert = plain(type(n) == 'number' and 2 or 1)
            end
            section = {command = n, name = ircd.numeric_name(net, n), columns = columns,
                convert = convert, rows = {}, sort = sorts[n]}
            by_command[n] = section
            table.insert(sections, section)
        end
        if lines then
            for _, text in ipairs(line_texts(lines, msg)) do
                table.insert(section.rows, {nonempty(text)})
            end
        else
            table.insert(section.rows, section.convert(msg))
        end
    end
    holder.view = {version = version, messages = messages, sections = sections}
    return sections
end

-- Rows ===============================================================

-- An error: its name, what it is about (the privilege missing, the
-- command refused), and its text
local function draw_error(ctx, win, msg)
    draw.red(win)
    local name = ircd.numeric_name(ctx.net, msg.command)
    win:waddstr(scrub(name or tostring(msg.command)), ':')
    for i = 2, #msg - 1 do win:waddstr(' ', scrub(msg[i])) end
    if #msg > 1 then win:waddstr(' ', scrub(msg[#msg])) end
    draw.normal(win)
end

--- The rows of messages as tables, for a kind's rows(ctx): rows given
--- to go first, each {count, draw(win, j)}; the errors; then for each
--- section with rows shown a blank row between, its heading, its header
--- and its rows; a note when there are no replies or none match; with a
--- filter how many match. A section's header stays above its rows
--- scrolled under it. The tables are kept on holder.
---@param ctx hub.ViewContext
---@param opts {holder: table, messages: hub.Message[], errors: hub.Message[]|nil,
--- relabel: table<string, string>|nil, lines: hub.ListingLines|nil, before: table[]|nil}
---@return integer count
---@return fun(win: ncurses.Window, i: integer) draw
---@return fun(i: integer): fun(win: ncurses.Window)|nil pinned
function M.runs(ctx, opts)
    local pattern = control.filter(ctx.id)
    local sections = sections_of(ctx.net, opts.holder, opts.messages, opts.relabel, opts.lines)

    -- the rows in runs, each {count, draw(win, j), layout, section}: a run
    -- of a section's rows has the last two, for the header to pin
    local runs = {}
    local function run(count, f, layout, section)
        if count > 0 then table.insert(runs, {count, f, layout, section}) end
    end
    for _, r in ipairs(opts.before or {}) do run(r[1], r[2]) end
    local errors = opts.errors or {}
    run(#errors, function(win, j) draw_error(ctx, win, errors[j]) end)

    local matched = 0
    for _, section in ipairs(sections) do
        local layout, shown = tables.of(section, section.columns, section.rows, pattern)
        matched = matched + #shown
        if #shown > 0 then
            if runs[1] then run(1, function() end) end
            run(1, function(win)
                draw.green(win)
                draw.bold(win)
                win:waddstr(scrub(section.name or tostring(section.command)))
                draw.normal(win)
                if section.name then win:waddstr(' ', tostring(section.command)) end
                draw.muted(win)
                win:waddstr(pattern and string.format('  %d of %d', #shown, #section.rows)
                    or string.format('  %d', #section.rows))
                draw.normal(win)
            end)
            run(1, function(win) tables.draw_header(win, layout, section) end)
            run(#shown, function(win, j) tables.draw_row(win, layout, shown[j]) end, layout, section)
        end
    end

    local total = #opts.messages
    if matched == 0 then
        run(1, function(win)
            draw.yellow(win)
            win:waddstr(total == 0 and 'no replies' or 'no reply matches')
            draw.normal(win)
        end)
    end
    if pattern then
        run(1, function(win)
            draw.yellow(win)
            win:waddstr(string.format('%d of %d %s match', matched, total, total == 1 and 'reply' or 'replies'))
            draw.normal(win)
        end)
    end

    local count = 0
    for _, r in ipairs(runs) do count = count + r[1] end
    return count, function(win, i)
        for _, r in ipairs(runs) do
            if i <= r[1] then return r[2](win, i) end
            i = i - r[1]
        end
    end, function(i)
        for _, r in ipairs(runs) do
            if i <= r[1] then
                local layout, section = r[3], r[4]
                return layout and function(win) tables.draw_header(win, layout, section) end
            end
            i = i - r[1]
        end
    end
end

function M.rows(ctx)
    ---@type hub.Listing
    local l = ctx.vs.data
    return M.runs(ctx, {holder = l, messages = l.messages, errors = l.errors, relabel = l.relabel,
        lines = l.lines})
end

return M
