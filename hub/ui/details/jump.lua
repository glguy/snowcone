-- The buffers of a network to jump to, in the detail pane (j in the
-- buffer view). Each has a label, 0-9, a-z, then A-Z: typing it, or
-- clicking the buffer, shows that buffer and closes the pane. A buffer
-- keeps its label while it exists, across renames, so closing another
-- doesn't move it; a new buffer takes the first free one, and past 62
-- there are none, but a click still works. A buffer configured with a
-- label ([[networks.buffers]]) has that one, and no other buffer takes
-- it, open or not; one configured with label = false has none. A hidden
-- one isn't listed, but has a label like any other and its key works.
--
-- The buffers go in columns by name, each column as wide as its widest
-- name, so one long name widens only its own; names past name_cap cells
-- are cut. Unseen messages color a name as in the status bar, yellow,
-- or magenta for a mention; the shown buffer is underlined. After the
-- label, → marks where Meta-A goes, ← where Meta-S goes back, and ↔ a
-- buffer that is both.
-- Labels live in the buffer view's state: labels[buffer] = label.

local chat    <const> = require 'hub.features.chat'
local common  <const> = require 'hub.features.common'
local control <const> = require 'hub.ui.control'
local draw    <const> = require 'hub.ui.draw'
local scrub   <const> = require 'hub.lib.scrub'

local M = {kind = 'jump'}

local alphabet <const> = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

-- The most cells a name takes, and the space between columns
local name_cap <const> = 24
local gap <const> = 2

local function width(text)
    return utf8.len(text) or #text
end

-- text cut to n cells, ending in … when cut
local function cut(text, n)
    if width(text) <= n then return text end
    return text:sub(1, (utf8.offset(text, n) or #text + 1) - 1) .. '…'
end

--- The labels, weak in the buffers so a closed one's label is free.
---@return table<table, string>
local function labels()
    local vs = control.view_state 'buffer'
    if not vs.labels then vs.labels = setmetatable({}, {__mode = 'k'}) end
    return vs.labels
end

--- The network's buffers sorted by folded name, each {key, buffer,
--- configured label, hidden}, every one labeled while labels last.
local function entries(net)
    local list = {}
    for key, buffer in pairs(chat.get(net).buffers) do
        local settings = chat.settings(net, buffer.name)
        table.insert(list, {key, buffer, settings and settings.label, settings and settings.hidden})
    end
    table.sort(list, function(a, b) return a[1] < b[1] end)

    -- configured labels are kept for their buffers, open or not
    local rec = HUB.state.nets[net]
    local used = {}
    for _, buffer in ipairs(rec and rec.cfg.buffers or {}) do
        if buffer.label then used[buffer.label] = true end
    end

    local L = labels()
    for _, entry in ipairs(list) do
        local buffer, configured = entry[2], entry[3]
        if configured ~= nil then
            L[buffer] = configured or nil
        elseif L[buffer] and used[L[buffer]] then
            L[buffer] = nil
        elseif L[buffer] then
            used[L[buffer]] = true
        end
    end
    local next_free = 1
    for _, entry in ipairs(list) do
        if not L[entry[2]] and entry[3] == nil then
            while next_free <= #alphabet and used[alphabet:sub(next_free, next_free)] do
                next_free = next_free + 1
            end
            if next_free > #alphabet then break end
            local label = alphabet:sub(next_free, next_free)
            L[entry[2]] = label
            used[label] = true
        end
    end
    return list
end

local function jump(net, name)
    control.close_detail()
    control.set_current_net(net)
    control.set_talk_target(net, name)
    control.set_view 'buffer'
end

--- The fewest rows whose columns fit in cols: their count and the widths
--- of the columns.
---@param widths integer[] each cell's width, in order down the columns
---@param cols integer
---@return integer rows
---@return integer[] column_widths
local function layout(widths, cols)
    local n = #widths
    for rows = 1, n do
        local columns = {}
        local total = -gap
        for i, w in ipairs(widths) do
            local c = (i - 1) // rows + 1
            if not columns[c] then
                columns[c] = 0
                total = total + gap
            end
            if w > columns[c] then
                total = total + w - columns[c]
                columns[c] = w
            end
        end
        if total <= cols or rows == n then return rows, columns end
    end
    return 0, {}
end

function M.title()
    return 'jump'
end

function M.render(ctx, win)
    local net = ctx.net
    if not (net and common.enabled(net, 'chat')) then
        win:waddstr 'No buffers\n'
        return
    end
    local list = {}
    for _, entry in ipairs(entries(net)) do
        if not entry[4] then table.insert(list, entry) end
    end
    if #list == 0 then
        win:waddstr 'No buffers: /talk <target>\n'
        return
    end

    local current = control.talk_target(net)
    current = current and chat.fold(net, current)
    local ahead = chat.next_buffer(net, current or '', true)
    local back = HUB.state.ui.view == 'buffer' and control.view_state 'buffer'.previous
    back = back and back[net]
    back = back and chat.buffer(net, back)

    -- each cell: label, mark, name; the rows stop short of the last
    -- column, so none wraps
    local L = labels()
    local names, widths = {}, {}
    local room = ctx.cols - 1
    local cap = math.max(1, math.min(name_cap, room - 2))
    for i, entry in ipairs(list) do
        names[i] = cut(scrub(entry[2].name), cap)
        widths[i] = 2 + width(names[i])
    end
    local rows, columns = layout(widths, room)

    for row = 1, rows do
        for c = 1, #columns do
            local i = (c - 1) * rows + row
            local entry = list[i]
            if not entry then break end
            local key, buffer = entry[1], entry[2]
            if c > 1 then
                win:waddstr(string.rep(' ', columns[c - 1] - widths[i - rows] + gap))
            end
            local y, x1 = ncurses.getyx(win)

            draw.bold(win)
            win:waddstr(L[buffer] or ' ')
            draw.normal(win)
            local mark = ' '
            if buffer == ahead and buffer == back then mark = '↔'
            elseif buffer == ahead then mark = '→'
            elseif buffer == back then mark = '←'
            end
            win:waddstr(mark)
            if buffer.activity > 0 then
                if buffer.mention then draw.magenta(win) else draw.yellow(win) end
            end
            if key == current then draw.underline(win) end
            win:waddstr(names[i])
            draw.normal(win)

            local _, x2 = ncurses.getyx(win)
            local name = buffer.name
            ctx.add_click(y, x1, x2, function() jump(net, name) end)
        end
        win:waddstr '\n'
    end
end

-- Every label character is taken while the pane is shown, assigned or
-- not, so a key never means something else for want of a buffer; a
-- hidden buffer's label works too
function M.keypress(ctx, key)
    if key < 0 or key > 0x7f then return false end
    local char = string.char(key)
    if not alphabet:find(char, 1, true) then return false end
    local net = ctx.net
    if not (net and common.enabled(net, 'chat')) then return true end
    for _, entry in ipairs(entries(net)) do
        if labels()[entry[2]] == char then
            jump(net, entry[2].name)
            break
        end
    end
    return true
end

return M
