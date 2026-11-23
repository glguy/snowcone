-- A listing (hub.Listing, features/listing.lua: STATS, TRACE, ETRACE,
-- MASKTRACE) in the detail pane: the errors the server gave, then a table
-- (ui/table.lua) per kind of reply, in the order they first came, each
-- under its numeric and how many there are. M.runs draws any replies so,
-- as a /quote's table view does (ui/details/reply.lua).
--
-- A table's columns are the reply's fields as the network names them
-- (ui/details/solanum.lua or hybrid.lua), its values read for what they
-- mean: times as dates, seconds and minutes as durations, ban types by
-- name, a reason apart from its oper reason, an address the server won't
-- give as "-". Auth blocks (STATS I) have their flags read out, and links
-- (STATS L) the times their last argument holds. A reply the network
-- doesn't name the fields of is one column of text: its arguments, after
-- our nick for a numeric.
--
-- The rows, their cells and the tables are worked out once and kept on
-- the listing, for its list of messages: a STATS can have tens of
-- thousands of rows, and only those shown are drawn. The filter (Ctrl-S, /filter) shows the rows with a
-- cell that matches.

local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local message <const> = require 'hub.ui.details.message'
local N       <const> = require 'hub.lib.numerics'
local scrub   <const> = require 'hub.lib.scrub'
local solanum <const> = require 'hub.ui.details.solanum'
local tables  <const> = require 'hub.ui.table'

local M = {kind = 'listing', filter = true, wide = true}

M.events = {
    ['listing.ready'] = function(ev) return ev.net, ev.listing end,
}

function M.title(detail)
    ---@type hub.Listing
    local l = detail.data
    local n = #l.messages
    return string.format('%s (%d %s)', scrub(l.command), n, n == 1 and 'reply' or 'replies')
end

-- Cells ==============================================================

-- A column whose cells are the i-th of a row's
local function column(i, header, formatted, optional)
    return {header = header, text = function(cells) return cells[i] end, formatted = formatted,
        optional = optional}
end

local function nonempty(value)
    if value ~= nil and value ~= '' then return value end
end

-- A value of a field's kind, as its cell shows it
local function cell_of(meant, kind, value)
    local n = tonumber(value)
    if kind == 'time' and n then return draw.date('%Y-%m-%d %H:%M', n) end
    if kind == 'secs' and n then return draw.duration(n) end
    if kind == 'mins' and n then return n == 0 and 'permanent' or draw.duration(n * 60) end
    if kind == 'line' then return meant.line_types[value] or value end
    if kind == 'addr' then return solanum.address(value) end
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
                    c = c + 1
                end
            end
        end
        if i <= #msg then cells[more] = table.concat(msg, ' ', i) end
        return cells
    end
end

-- Replies whose cells take reading of their own
local special <const> = {}

-- An auth block (STATS I): I <name> <password> <sigils><user>@<host>
-- <port> <class> :<description>, read as the message detail reads it
special[N.RPL_STATSILINE] = function(meant)
    local sigils = {}
    for sigil in pairs(meant.auth_flags) do table.insert(sigils, '%' .. sigil) end
    local flags_pattern = '^([' .. table.concat(sigils) .. ']*)([^@]*)@(.*)$'
    local columns = {
        column(1, 'mask'), column(2, 'flags', false, true), column(3, 'class'),
        column(4, 'spoof or redirect', false, true), column(5, 'port', false, true),
        column(6, 'password', false, true), column(7, 'description', true, true),
    }
    return columns, function(msg)
        local name, password, mask, port, class = msg[3], msg[4], msg[5] or '', msg[6], msg[7]
        local prefix, user, host = mask:match(flags_pattern)
        if not prefix then prefix, user, host = '', mask, nil end
        local flags, spoof = {}, false
        for sigil in prefix:gmatch '.' do
            table.insert(flags, meant.auth_flags[sigil])
            if sigil == '=' then spoof = true end
        end
        local named, redirect
        if spoof then
            -- hybrid gives * for a block without a spoof name
            if name ~= '*' then named = name end
        elseif meant.auth_redirects and name ~= 'NOMATCH' and name ~= '<NULL>' then
            named, redirect = name, true
        end
        local shown_password
        if meant.auth_passwords and password and password ~= '<NULL>' then
            shown_password = password == '*' and '(hidden)' or password
        end
        return {
            user .. '@' .. (host == '255.255.255.255' and '(hidden)' or host or '?'),
            flags[1] and table.concat(flags, ','),
            class,
            nonempty(named),
            redirect and port ~= '0' and nonempty(port) or nil,
            shown_password,
            #msg > 7 and nonempty(msg[#msg]) or nil,
        }
    end
end

-- A link (STATS L): <name> <sendq> <sent messages> <sent KiB> <received
-- messages> <received KiB> :<seconds open> <seconds idle> <capabilities>
special[N.RPL_STATSLINKINFO] = function()
    local columns = {
        column(1, 'link'), column(2, 'sendq'), column(3, 'sent msgs'), column(4, 'sent KiB'),
        column(5, 'recv msgs'), column(6, 'recv KiB'), column(7, 'open'), column(8, 'idle'),
        column(9, 'caps', false, true),
    }
    return columns, function(msg)
        local open, idle, caps = (msg[8] or ''):match '^(%d+) (%d+) ?(.*)$'
        return {
            msg[2], msg[3], msg[4], msg[5], msg[6], msg[7],
            open and draw.duration(open) or nonempty(msg[8]),
            idle and draw.duration(idle),
            caps ~= '-' and nonempty(caps) or nil,
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

--- The sections of messages, worked out once and kept on holder for
--- those messages: {numeric, name, columns, rows}, a row the cells of a
--- reply.
---@param net string|nil
---@param holder table
---@param messages hub.Message[]
---@param relabel table<string, string>|nil
local function sections_of(net, holder, messages, relabel)
    local view = holder.view
    if view and view.version == version and view.messages == messages then return view.sections end
    local meant = message.meaning(net)
    local sections, by_command = {}, {}
    for _, msg in ipairs(messages) do
        local n = msg.command
        local section = by_command[n]
        if not section then
            local make = special[n]
            local columns, convert
            if make then
                columns, convert = make(meant)
            elseif meant.fields[n] then
                columns, convert = by_fields(meant, meant.fields[n], relabel)
            else
                columns, convert = plain(type(n) == 'number' and 2 or 1)
            end
            section = {command = n, name = message.numeric_name(net, n), columns = columns,
                convert = convert, rows = {}}
            by_command[n] = section
            table.insert(sections, section)
        end
        table.insert(section.rows, section.convert(msg))
    end
    holder.view = {version = version, messages = messages, sections = sections}
    return sections
end

-- Rows ===============================================================

-- An error: its name, what it is about (the privilege missing, the
-- command refused), and its text
local function draw_error(ctx, win, msg)
    draw.red(win)
    local name = message.numeric_name(ctx.net, msg.command)
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
--- relabel: table<string, string>|nil, before: table[]|nil}
---@return integer count
---@return fun(win: ncurses.Window, i: integer) draw
---@return fun(i: integer): fun(win: ncurses.Window)|nil pinned
function M.runs(ctx, opts)
    local pattern = control.filter(ctx.id)
    local sections = sections_of(ctx.net, opts.holder, opts.messages, opts.relabel)

    -- the rows in runs, each {count, draw(win, j), layout}: a run of a
    -- section's rows has its layout, for the header to pin
    local runs = {}
    local function run(count, f, layout)
        if count > 0 then table.insert(runs, {count, f, layout}) end
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
                draw.black(win)
                win:waddstr(pattern and string.format('  %d of %d', #shown, #section.rows)
                    or string.format('  %d', #section.rows))
                draw.normal(win)
            end)
            run(1, function(win) tables.draw_header(win, layout) end)
            run(#shown, function(win, j) tables.draw_row(win, layout, shown[j]) end, layout)
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
                local layout = r[3]
                return layout and function(win) tables.draw_header(win, layout) end
            end
            i = i - r[1]
        end
    end
end

function M.rows(ctx)
    ---@type hub.Listing
    local l = ctx.vs.data
    return M.runs(ctx, {holder = l, messages = l.messages, errors = l.errors, relabel = l.relabel})
end

return M
