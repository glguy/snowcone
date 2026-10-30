-- The labeled reply to a /quote (hub.QuoteReply, commands/core.lua) in
-- the detail pane: the line sent, then one row per reply message. Click a
-- command to inspect that message.

local addircstr <const> = require 'hub.ui.irc_formatting'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local message   <const> = require 'hub.ui.details.message'
local scrub     <const> = require 'hub.lib.scrub'

local M = {kind = 'reply'}

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
    win:waddstr '\n'
end

function M.render(ctx, win)
    ---@type hub.QuoteReply
    local reply = ctx.vs.data

    draw.blue(win)
    win:waddstr '>>> '
    draw.normal(win)
    win:waddstr(scrub(reply.line), '\n')

    local state = state_text[reply.state]
    if state then
        draw.yellow(win)
        win:waddstr(state, '\n')
        draw.normal(win)
    end

    for _, msg in ipairs(reply.messages) do
        draw_message(ctx, win, msg)
    end
end

return M
