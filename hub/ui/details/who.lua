-- A WHO reply (hub.Who, features/queries/who.lua) in the detail pane: a
-- table with a row per user and a column per field the reply gave, read
-- for what it means: the status's away, bot, operator and prefixes in
-- their colors, the address with its organization, the idle time as a
-- duration, and "-" for a field the server left empty (ui/table.lua,
-- which keeps its layout on the hub.Who). The table is wide, for Left and
-- Right; the filter (Ctrl-S, /filter) shows only the users with a field
-- that matches.

local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local scrub   <const> = require 'hub.lib.scrub'
local tables  <const> = require 'hub.ui.table'

local M = {kind = 'who', filter = true, wide = true}

M.events = {
    ['query.who'] = function(ev) return ev.net, ev.who end,
}

function M.title(detail)
    ---@type hub.Who
    local w = detail.data
    local n = #w.rows
    return string.format('%s %s%s (%d %s)', w.mask:find '^!' and 'operspy who' or 'who', scrub(w.mask),
        w.options and ' ' .. scrub(w.options) or '', n, n == 1 and 'user' or 'users')
end

function M.modes(detail)
    ---@type hub.Who
    local w = detail.data
    local modes = {}
    if w.truncated then table.insert(modes, 'truncated') end
    if w.opers_only then table.insert(modes, 'operators only') end
    if w.token then table.insert(modes, 'token ' .. scrub(w.token)) end
    return modes
end

-- The status's letters in their colors: G (away) yellow, the bot letter
-- magenta, * (operator) red, @ green and other prefixes yellow
local function paint_status(win, row)
    local status = scrub(row.status)
    local away = status:sub(1, 1)
    if away == 'G' then draw.yellow(win) end
    win:waddstr(away)
    draw.normal(win)
    for c in status:sub(2):gmatch '.' do
        if c == '*' then draw.red(win)
        elseif c == '@' then draw.green(win)
        elseif c:find '%a' then draw.magenta(win)
        else draw.yellow(win) end
        win:waddstr(c)
        draw.normal(win)
    end
end

local function org_text(row)
    if row.asn and row.org then return string.format('AS%d %s', row.asn, row.org) end
    if row.asn then return 'AS' .. row.asn end
    return row.org
end

local function nonzero_idle(row)
    -- 0 is what a server says for a user it doesn't know the idle time of
    if row.idle and row.idle > 0 then return draw.duration(row.idle) end
end

--- The columns (ui/table.lua), in the order shown, by the WHOX letter
--- that gives each; those of letters the reply didn't give are left out.
--- org isn't a field: it shows with the address, when one has an org.
local columns <const> = {
    {letter = 'n', header = 'nick', text = function(r) return r.nick end,
        paint = function(win, r)
            if r.away then draw.yellow(win) end
            if r.oper then draw.bold(win) end
            win:waddstr(scrub(r.nick))
            draw.normal(win)
        end},
    {letter = 'f', header = 'status', text = function(r) return r.status end, paint = paint_status},
    {letter = 'c', header = 'channel', text = function(r) return r.channel end},
    {letter = 'u', header = 'user', text = function(r) return r.user end},
    {letter = 'h', header = 'host', text = function(r) return r.host end},
    {letter = 'i', header = 'ip', text = function(r) return r.ip end},
    {letter = 'i', header = 'org', text = org_text, optional = true},
    {letter = 's', header = 'server', text = function(r) return r.server end},
    {letter = 'd', header = 'hops', text = function(r) return r.hops and tostring(r.hops) end},
    {letter = 'l', header = 'idle', text = nonzero_idle},
    {letter = 'a', header = 'account', text = function(r) return r.account end,
        paint = function(win, r)
            draw.cyan(win)
            win:waddstr(scrub(r.account))
            draw.normal(win)
        end},
    {letter = 'o', header = 'oplevel', text = function(r)
        if r.oplevel == '999' then return 'op' end
    end},
    {letter = 'r', header = 'realname', text = function(r) return r.realname end, formatted = true},
}

--- The columns of the fields a reply gave, kept by its fields list.
local by_fields <const> = setmetatable({}, {__mode = 'k'})
local function columns_of(fields)
    local cols = by_fields[fields]
    if not cols then
        local given = {}
        for _, letter in ipairs(fields) do given[letter] = true end
        cols = {}
        for _, col in ipairs(columns) do
            if given[col.letter] then table.insert(cols, col) end
        end
        by_fields[fields] = cols
    end
    return cols
end

-- One row each: the header, each user the filter shows (or a note when
-- there are none), and with a filter how many it shows. The header stays
-- above the users scrolled under it.
function M.rows(ctx)
    ---@type hub.Who
    local w = ctx.vs.data
    local pattern = control.filter(ctx.id)
    local layout, shown = tables.of(w, columns_of(w.fields), w.rows, pattern)

    local body = math.max(#shown, 1)
    return 1 + body + (pattern and 1 or 0), function(win, i)
        if i == 1 then
            tables.draw_header(win, layout)
        elseif i <= 1 + #shown then
            tables.draw_row(win, layout, shown[i - 1])
        elseif i == 2 and #shown == 0 then
            draw.yellow(win)
            win:waddstr(#w.rows == 0 and 'no users' or 'no user matches')
            draw.normal(win)
        else
            draw.yellow(win)
            win:waddstr(string.format('%d of %d %s match', #shown, #w.rows,
                #w.rows == 1 and 'user' or 'users'))
            draw.normal(win)
        end
    end, function(i)
        if i > 1 and i <= 1 + #shown then
            return function(win) tables.draw_header(win, layout) end
        end
    end
end

return M
