-- Tables for wide detail kinds: a header row, then a row per item and a
-- column per field, each as wide as its widest cell, with "-" for a cell
-- that has nothing. A reply can have tens of thousands of rows, so all
-- that looks at every row (the layout, the order, the text each row matches
-- the filter by, the rows a filter shows) is done once and kept on a holder
-- the caller gives, what the rows belong to; drawing touches only the
-- rows shown.
--
-- Click a column's header to sort by it, again to reverse, and once more
-- for the order the rows came in. The holder keeps the choice, in sort.
-- Rows without a cell in the column come last either way.
--
-- A column is {header, text(row), key(row), paint(win, row), formatted,
-- optional}: text gives the cell's text, nil for none; paint, when there
-- is one, draws it in color at the same width. A formatted column's text
-- has IRC formatting, drawn as such. key gives what a cell sorts by,
-- for text that doesn't sort as what it means: a number (a duration), or
-- text in lowercase hex (lib/address_key.lua); without one, or for nil,
-- the cell's text sorts, its runs of digits as numbers. Numbers come
-- before text. An optional column shows only when some row has a cell
-- in it. The last column shown isn't padded.

local addircstr <const> = require 'hub.ui.irc_formatting'
local clicks    <const> = require 'hub.ui.clicks'
local draw      <const> = require 'hub.ui.draw'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'
local strip     <const> = require 'hub.lib.strip_formatting'
local theme     <const> = require 'hub.ui.theme'

local M = {}

local function width(text)
    return utf8.len(text) or #text
end

-- A cell's text as it is drawn
local function shown(col, text)
    return col.formatted and scrub(strip(text)) or scrub(text)
end

--- The columns shown and their widths: a list of {col, index, width},
--- index the column's place in columns.
---@param columns table[]
---@param rows any[]
---@return table[]
function M.layout(columns, rows)
    local out = {}
    for index, col in ipairs(columns) do
        local cell, any = 0, false
        for _, row in ipairs(rows) do
            local text = col.text(row)
            if text then
                any = true
                cell = math.max(cell, width(shown(col, text)))
            end
        end
        if any or not col.optional then
            table.insert(out, {col = col, index = index, width = math.max(cell, width(col.header), 1)})
        end
    end
    return out
end

--- What the filter matches in a row: every cell, without formatting.
local function haystack(columns, row)
    local parts = {}
    for _, col in ipairs(columns) do
        local text = col.text(row)
        if text then table.insert(parts, col.formatted and strip(text) or text) end
    end
    return table.concat(parts, ' ')
end

local hex <const> = {}
for i = 0, 255 do hex[string.char(i)] = string.format('%02x', i) end

-- A key that orders text as people read it: without ASCII case, and runs
-- of digits as numbers, each after its length. The key is in hex, whose
-- order is that of the bytes: < collates by the locale, which isn't a
-- consistent order for text that isn't UTF-8, as table.sort needs.
local function natural(text)
    text = text:gsub('[A-Z]+', string.lower):gsub('%d+', function(d)
        d = d:gsub('^0+', '')
        return '0' .. string.char(math.min(#d, 255)) .. d
    end)
    return (text:gsub('.', hex))
end

--- The rows in order of a column, numbers before text and rows without a
--- cell last; those alike stay in the order they came.
local function sorted(col, rows, descending)
    local numbers, texts, out, place, missing = {}, {}, {}, {}, {}
    for i, row in ipairs(rows) do
        local text = col.text(row)
        if text then
            local key = col.key and col.key(row)
            if type(key) == 'number' then
                numbers[row] = key
            elseif key then
                texts[row] = key
            else
                texts[row] = natural(shown(col, text))
            end
            place[row] = i
            table.insert(out, row)
        else
            table.insert(missing, row)
        end
    end
    table.sort(out, function(a, b)
        local x, y = numbers[a], numbers[b]
        if (x == nil) ~= (y == nil) then
            return (x ~= nil) ~= descending
        end
        if x == nil then x, y = texts[a], texts[b] end
        if x < y then return not descending end
        if y < x then return descending end
        return place[a] < place[b]
    end)
    table.move(missing, 1, #missing, #out + 1, out)
    return out
end

--- The table of rows under columns, kept on holder: its layout, and the
--- rows the filter pattern shows (all of them without one), in the order
--- of holder.sort. A holder whose
--- columns aren't these, as after a reload, is worked out again.
---@param holder table
---@param columns table[]
---@param rows any[]
---@param pattern string|nil
---@return table[] layout
---@return any[] shown
function M.of(holder, columns, rows, pattern)
    local t = holder.table
    if not (t and t.columns == columns and t.rows == rows) then
        t = {columns = columns, rows = rows, layout = M.layout(columns, rows)}
        holder.table = t
    end
    local sort = holder.sort
    local col = sort and columns[sort.column]
    local ordered = rows
    if sort and col then
        local o = t.ordered
        if not (o and o.column == sort.column and o.descending == sort.descending) then
            o = {column = sort.column, descending = sort.descending,
                rows = sorted(col, rows, sort.descending)}
            t.ordered = o
        end
        ordered = o.rows
    end

    if not pattern then return t.layout, ordered end
    if not (t.matches and t.matches.pattern == pattern and t.matches.ordered == ordered) then
        if not t.haystacks then
            t.haystacks = {}
            for _, row in ipairs(rows) do t.haystacks[row] = haystack(columns, row) end
        end
        local list = {}
        for _, row in ipairs(ordered) do
            if matching.safematch(t.haystacks[row], pattern) then table.insert(list, row) end
        end
        t.matches = {pattern = pattern, ordered = ordered, rows = list}
    end
    return t.layout, t.matches.rows
end

-- A click on the header of a column: ascending, descending, unsorted
local function sort_by(holder, index)
    local sort = holder.sort
    if not (sort and sort.column == index) then
        holder.sort = {column = index, descending = false}
    elseif not sort.descending then
        holder.sort = {column = index, descending = true}
    else
        holder.sort = nil
    end
end

--- Draw the header row, each column's a button to sort the holder's table
--- by it, with ▲ or ▼ in the gap after the one it is sorted by: bold in the heading color on the modern theme,
--- blue on the classic.
function M.draw_header(win, layout, holder)
    local heading = theme.text 'heading'
    if heading then
        ncurses.colorset(heading, select(2, draw.base(win)), win)
        draw.bold(win)
    else
        draw.blue(win)
    end
    for i, c in ipairs(layout) do
        local header, sort = c.col.header, holder.sort
        local text = header
        if sort and sort.column == c.index then text = text .. (sort.descending and '▼' or '▲') end
        -- the whole column's width, for a wider target, within the window:
        -- a button that wraps can't be clicked
        local _, x = ncurses.getyx(win)
        local room = select(2, ncurses.getmaxyx(win)) - x - 1
        if width(text) > room then break end
        local padding = math.min(c.width, room) - width(text)
        clicks.button(win, text .. string.rep(' ', padding),
            function() sort_by(holder, c.index) end, true)
        if c.width >= room then break end
        -- a mark may have taken the gap
        if i < #layout and width(text) <= c.width then win:waddstr ' ' end
    end
    draw.normal(win)
end

--- Draw a row.
function M.draw_row(win, layout, row)
    for i, c in ipairs(layout) do
        local col = c.col
        local text = col.text(row)
        local used
        if text == nil then
            draw.muted(win)
            win:waddstr '-'
            draw.normal(win)
            used = 1
        else
            if col.paint then
                col.paint(win, row)
            elseif col.formatted then
                addircstr(win, text)
                draw.normal(win)
            else
                win:waddstr(scrub(text))
            end
            used = width(shown(col, text))
        end
        if i < #layout then win:waddstr(string.rep(' ', c.width - used + 1)) end
    end
end

return M
