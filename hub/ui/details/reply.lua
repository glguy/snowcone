-- The labeled reply to a /quote (hub.QuoteReply, commands/core.lua) in
-- the detail pane: the line sent, then one row per reply message. Click a
-- command to inspect that message. The filter (Ctrl-S, /filter) shows only
-- the messages that match.

local addircstr <const> = require 'hub.ui.irc_formatting'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local matching  <const> = require 'hub.lib.matching'
local message   <const> = require 'hub.ui.details.message'
local scrub     <const> = require 'hub.lib.scrub'

local M = {kind = 'reply', filter = true, wide = true}

M.events = {
    ['quote.sent'] = function(ev) return ev.net, ev.reply end,
}

function M.title(detail)
    return 'reply ' .. scrub(detail.data.line)
end

local state_text <const> = {
    waiting = 'waiting for the reply',
    timeout = 'no reply',
}

local function draw_message(ctx, win, msg)
    -- the source without its user and host
    draw.yellow(win)
    local source = msg.source and msg.source:match '^[^.!]*' or ''
    win:waddstr(string.format('%-16.16s ', scrub(source)))

    local color = message.palette[msg.command]
    if color then color(win) end
    draw.bold(win)
    local name = message.numeric_names[msg.command]
    local label = scrub(tostring(msg.command)) .. (name and ' ' .. name or '')
    ctx.add_button(win, label, function()
        control.open_detail('message', ctx.net, msg)
    end, true)
    draw.normal(win)

    -- a numeric's first argument is our nick
    local first = type(msg.command) == 'number' and 2 or 1
    for i = first, #msg do
        win:waddstr ' '
        addircstr(win, msg[i])
    end
end

-- What the filter matches: the source, the command and its numeric
-- name, and the arguments
local function haystack(msg)
    local name = message.numeric_names[msg.command]
    local parts = {msg.source or '', tostring(msg.command), name or ''}
    for _, arg in ipairs(msg) do table.insert(parts, arg) end
    return table.concat(parts, ' ')
end

-- One row each: the line sent, the state while there is no reply, the
-- messages the filter shows, and with a filter how many it shows
function M.rows(ctx)
    ---@type hub.QuoteReply
    local reply = ctx.vs.data
    local state = state_text[reply.state]
    local pattern = control.filter(ctx.id)

    local shown = reply.messages
    if pattern then
        shown = {}
        for _, msg in ipairs(reply.messages) do
            if matching.safematch(haystack(msg), pattern) then
                table.insert(shown, msg)
            end
        end
    end

    local head = state and 2 or 1
    return head + #shown + (pattern and 1 or 0), function(win, i)
        if i == 1 then
            draw.blue(win)
            win:waddstr '>>> '
            draw.normal(win)
            win:waddstr(scrub(reply.line))
        elseif i <= head then
            draw.yellow(win)
            win:waddstr(state)
            draw.normal(win)
        elseif i <= head + #shown then
            draw_message(ctx, win, shown[i - head])
        else
            draw.yellow(win)
            win:waddstr(string.format('%d of %d %s match', #shown, #reply.messages,
                #reply.messages == 1 and 'message' or 'messages'))
            draw.normal(win)
        end
    end
end

return M
