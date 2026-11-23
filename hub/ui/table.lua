-- Tables for wide detail kinds: a header row, then a row per item and a
-- column per field, each as wide as its widest cell, with "-" for a cell
-- that has nothing. A reply can have tens of thousands of rows, so all
-- that looks at every row (the layout, the text each row matches the
-- filter by, the rows a filter shows) is done once and kept on a holder
-- the caller gives, the list the rows belong to; drawing touches only the
-- rows shown.
--
-- A column is {header, text(row), paint(win, row), formatted, optional}:
-- text gives the cell's text, nil for none; paint, when there is one,
-- draws it in color at the same width. A formatted column's text has IRC
-- formatting, drawn as such. An optional column shows only when some row
-- has a cell in it. The last column shown isn't padded.

local addircstr <const> = require 'hub.ui.irc_formatting'
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

--- The columns shown and their widths: a list of {col, width}.
---@param columns table[]
---@param rows any[]
---@return table[]
function M.layout(columns, rows)
    local out = {}
    for _, col in ipairs(columns) do
        local cell, any = 0, false
        for _, row in ipairs(rows) do
            local text = col.text(row)
            if text then
                any = true
                cell = math.max(cell, width(shown(col, text)))
            end
        end
        if any or not col.optional then
            table.insert(out, {col = col, width = math.max(cell, width(col.header), 1)})
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

--- The table of rows under columns, kept on holder: its layout, and the
--- rows the filter pattern shows (all of them without one). A holder whose
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
    if not pattern then return t.layout, rows end
    if not (t.matches and t.matches.pattern == pattern) then
        if not t.haystacks then
            t.haystacks = {}
            for i, row in ipairs(rows) do t.haystacks[i] = haystack(columns, row) end
        end
        local list = {}
        for i, row in ipairs(rows) do
            if matching.safematch(t.haystacks[i], pattern) then table.insert(list, row) end
        end
        t.matches = {pattern = pattern, rows = list}
    end
    return t.layout, t.matches.rows
end

--- Draw the header row: bold in the heading color on the modern theme,
--- blue on the classic.
function M.draw_header(win, layout)
    local heading = theme.text 'heading'
    if heading then
        ncurses.colorset(heading, select(2, draw.base(win)), win)
        draw.bold(win)
    else
        draw.blue(win)
    end
    for i, c in ipairs(layout) do
        win:waddstr(c.col.header)
        if i < #layout then win:waddstr(string.rep(' ', c.width - width(c.col.header) + 1)) end
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
