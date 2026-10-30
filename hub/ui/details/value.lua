-- Lua values in the detail pane, from /eval: one row per result, and a
-- table as a tree. [+] opens a table's entries below it, indented, keys
-- in order (numbers, then strings, then the rest); a table shows its
-- first entries and a button for the rest. The values are the live
-- ones, so the pane shows them as they are now. A table inside itself
-- shows as a cycle.

local draw  <const> = require 'hub.ui.draw'
local scrub <const> = require 'hub.lib.scrub'

local M = {kind = 'value'}

-- Entries a table shows before its [+N more]
local shown_entries <const> = 50
-- Bytes of a string shown
local string_limit <const> = 300

-- tostring, which a __tostring can break
local function safe_tostring(v)
    local ok, text = pcall(tostring, v)
    if ok and type(text) == 'string' then return text end
    return '?'
end

local type_rank <const> = {number = 1, string = 2}

local function key_less(a, b)
    local ra, rb = type_rank[type(a)] or 3, type_rank[type(b)] or 3
    if ra ~= rb then return ra < rb end
    if ra == 3 then
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return safe_tostring(a) < safe_tostring(b)
    end
    return a < b
end

-- Names a key within its table for the open and expanded sets
local function key_id(k)
    return type(k):sub(1, 1) .. ':' .. safe_tostring(k)
end

-- The first `limit` bytes of a string, not ending inside a character
local function cut(s, limit)
    if #s <= limit then return s end
    local n = limit
    while n > 0 and s:byte(n + 1) and s:byte(n + 1) & 0xc0 == 0x80 do
        n = n - 1
    end
    return s:sub(1, n) .. '…'
end

local function scalar(win, v)
    local t = type(v)
    if t == 'string' then
        draw.green(win)
        win:waddstr('"', scrub(cut(v, string_limit)), '"')
    elseif t == 'number' then
        draw.magenta(win)
        win:waddstr(safe_tostring(v))
    elseif t == 'boolean' or t == 'nil' then
        draw.yellow(win)
        win:waddstr(tostring(v))
    else
        draw.blue(win)
        win:waddstr(scrub(safe_tostring(v)))
    end
    draw.normal(win)
end

local function key_text(win, k)
    if type(k) == 'string' and k:match '^[%a_][%w_]*$' then
        draw.cyan(win)
        win:waddstr(k)
        draw.normal(win)
    else
        win:waddstr '['
        scalar(win, k)
        win:waddstr ']'
    end
    win:waddstr ' = '
end

-- Draw a value and, for an open table, its entries on the rows below
local function render_value(ctx, win, v, id, indent, ancestors)
    if type(v) ~= 'table' then
        scalar(win, v)
        win:waddstr '\n'
        return
    end
    if ancestors[v] then
        draw.yellow(win)
        win:waddstr('cycle: ', scrub(safe_tostring(v)), '\n')
        draw.normal(win)
        return
    end

    local keys = {}
    for k in next, v do keys[#keys + 1] = k end
    if #keys == 0 then
        win:waddstr '{}\n'
        return
    end

    local vs = ctx.vs
    local open = vs.open[id]
    ctx.add_button(win, open and '[-]' or '[+]', function() vs.open[id] = not open or nil end)
    win:waddstr(' ', scrub(safe_tostring(v)))
    draw.blue(win)
    win:waddstr(string.format(' %d %s\n', #keys, #keys == 1 and 'entry' or 'entries'))
    draw.normal(win)
    if not open then return end

    table.sort(keys, key_less)
    local limit = vs.all[id] and #keys or math.min(#keys, shown_entries)
    local margin = string.rep(' ', indent)
    ancestors[v] = true
    for i = 1, limit do
        local k = keys[i]
        win:waddstr(margin)
        key_text(win, k)
        render_value(ctx, win, rawget(v, k), id .. '/' .. key_id(k), indent + 2, ancestors)
    end
    ancestors[v] = nil
    if limit < #keys then
        win:waddstr(margin)
        ctx.add_button(win, string.format('[+%d more]', #keys - limit), function() vs.all[id] = true end)
        win:waddstr '\n'
    end
end

function M.title(detail)
    local code = detail.data.code or ''
    return 'eval ' .. scrub(cut(code:match '^[^\n]*', 40))
end

function M.render(ctx, win)
    local vs = ctx.vs
    local value = vs.data
    -- results start open
    if not vs.open then
        vs.open, vs.all = {}, {}
        for i = 1, value.n do vs.open[tostring(i)] = true end
    end
    for i = 1, value.n do
        draw.blue(win)
        win:waddstr(string.format('%3d: ', i))
        draw.normal(win)
        render_value(ctx, win, value[i], tostring(i), 5, {})
    end
end

return M
