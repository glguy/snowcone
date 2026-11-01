-- An IRC message in the detail pane, at one of three levels, which the
-- buttons at the top switch between: a summary of what it means, for a
-- command that has one; the message as the server sent it (tags, source,
-- our delivery and the server's receipt, command and arguments); and that
-- with its strings escaped. It opens at the summary when there is one.
-- Also the command colors and notice matching the console shares.

local addircstr   <const> = require 'hub.ui.irc_formatting'
local draw        <const> = require 'hub.ui.draw'
local irc_model   <const> = require 'hub.net.irc'
local numerics    <const> = require 'hub.lib.numerics'
local parse_snote <const> = require 'hub.features.snotice.parse'
local scrub       <const> = require 'hub.lib.scrub'
local tablex      <const> = require 'pl.tablex'

local M = {kind = 'message'}

--- Colors of commands; errors are red.
M.palette = {
    PRIVMSG = draw.blue,
    NOTICE = draw.cyan,
    JOIN = draw.green,
    PART = draw.yellow,
    QUIT = draw.magenta,
}

--- Names of numerics, by number.
local numeric_names = {}
M.numeric_names = numeric_names
for name, numeric in pairs(numerics) do
    numeric_names[numeric] = name
    if name:sub(1, 4) == 'ERR_' then
        M.palette[numeric] = draw.red
    end
end

--- The body of a server notice, without its header, or nil.
function M.snotice_text(msg)
    if msg.source and msg.command == 'NOTICE'
    and msg[1] == '*' and #msg == 2
    and msg[2]:sub(1, 14) == '*** Notice -- ' then
        return msg[2]:sub(15)
    end
end

--- The parsed form of a server notice (without the time, which the
--- message shows), or nil for any other message.
function M.decode(msg)
    local text = M.snotice_text(msg)
    return text and parse_snote(msg.source, text)
end

local escapes <const> = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\a'] = '\\a',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\v'] = '\\v',
}

local function rawstr(str)
    str = string.gsub(str, '[\x00-\x1f"\\\x7f-\xff]', function(c)
        return escapes[c] or string.format('\\x%02x', string.byte(c))
    end)
    return '"' .. str .. '"'
end

function M.title(detail)
    local msg = detail.data
    local name = numeric_names[msg.command]
    return string.format('message %s%s', scrub(tostring(msg.command)), name and ' ' .. name or '')
end

-- Shared parts ======================================================

-- The protocol model of the detail's network, nil while it is idle
local function net_irc(ctx)
    local rec = ctx.net and HUB.state.nets[ctx.net]
    return rec and rec.irc
end

-- A label in the label column, `width` wide (10 by default), leaving the
-- color normal for its value
local function field(win, label, width)
    draw.blue(win)
    win:waddstr(string.format('%' .. (width or 10) .. 's: ', label))
    draw.normal(win)
end

local function delivery_fields(win, msg)
    local delivery = msg.delivery
    if delivery then
        field(win, 'delivery')
        if delivery.state == 'sent' then
            win:waddstr(string.format('sent after %.1f s in the queue\n', delivery.delay))
        else
            win:waddstr(delivery.state, '\n')
        end
    end

    local receipt = msg.receipt
    if receipt then
        field(win, 'receipt')
        win:waddstr(receipt)
        if msg.rejection then
            win:waddstr(': ', scrub(msg.rejection))
        end
        win:waddstr '\n'
    end
end

-- Width of a chat summary's label column
local chat_width <const> = 8

-- A line of a chat summary: its label, then each part {text, color}, the
-- text scrubbed already, separated by commas, wrapping under the first.
-- Nothing without a part.
local function line(ctx, win, label, parts)
    if #parts == 0 then return end
    field(win, label, chat_width)
    for i, part in ipairs(parts) do
        if part[2] then part[2](win) end
        draw.wrap_text(win, (i > 1 and ' ' or '') .. part[1] .. (i < #parts and ',' or ''),
            ctx.cols, chat_width + 2)
        draw.normal(win)
    end
    win:waddstr '\n'
end

-- The sender's prefix modes in a channel as of the message, read out
local function rank_text(irc, msg)
    if msg.history then return 'rank unknown, from history' end
    local modes = msg.member_modes
    if not modes then return 'not a member' end
    local prefixes, letters = {}, {}
    if irc then
        for i = 1, #irc.prefixes do
            local p = irc.prefixes:sub(i, i)
            local mode = irc.prefix_to_mode[p]
            if mode and modes[mode] then
                table.insert(prefixes, p)
                table.insert(letters, mode)
            end
        end
    end
    -- modes the network no longer has a prefix for
    for mode in tablex.sort(modes) do
        if not tablex.find(letters, mode) then table.insert(letters, mode) end
    end
    if #letters == 0 then return 'no channel modes' end
    local text = '+' .. table.concat(letters)
    if #prefixes > 0 then text = table.concat(prefixes) .. ' ' .. text end
    return text
end

-- A tag's value, or nil when it has none
local function tag_value(tags, key)
    local v = tags[key]
    if v ~= nil and v ~= true and v ~= '' then return v end
end

-- Who sent the message, on three lines: where it came from, the identity
-- behind it, and its role (rank in the channel, bot, oper)
local function sender(ctx, irc, win, msg, channel)
    local tags = msg.tags
    local ours = msg.source == '>>>'

    local from, identity, role = {}, {}, {}
    if ours then
        table.insert(from, {'us', draw.bold})
        if irc and irc.nick then table.insert(from, {scrub(irc.nick)}) end
    elseif msg.nick then
        local nick = scrub(msg.nick)
        if msg.user or msg.host then
            nick = nick .. ' ' .. scrub(msg.user or '?') .. '@' .. scrub(msg.host or '?')
        end
        table.insert(from, {nick, draw.bold})
        local realhost = tag_value(tags, 'solanum.chat/realhost')
        if realhost then table.insert(from, {'real host ' .. scrub(realhost)}) end

        local caps = irc and irc.caps_enabled or {}
        local account = tag_value(tags, 'account')
        if account then
            table.insert(identity, {'account ' .. scrub(account)})
            if irc and irc_model.fold(irc, account) ~= irc_model.fold(irc, msg.nick) then
                table.insert(identity, {'not the nick', draw.yellow})
            end
        elseif caps['account-tag'] then
            table.insert(identity, {'not logged in', draw.yellow})
        end
        if tags['solanum.chat/identify-msg'] ~= nil then
            table.insert(identity, {'identified', draw.green})
        elseif caps['solanum.chat/identify-msg'] then
            table.insert(identity, {'not identified', draw.yellow})
        end

        if tags.bot ~= nil or tags['draft/bot'] ~= nil then
            table.insert(role, {'bot', draw.magenta})
        end
        local oper = tags['solanum.chat/oper']
        if oper ~= nil then
            local name = tag_value(tags, 'solanum.chat/oper')
            table.insert(role, {name and 'oper ' .. scrub(name) or 'oper', draw.green})
        end
    elseif msg.source then
        table.insert(from, {scrub(msg.source), draw.bold})
        table.insert(from, {'server'})
    end
    if channel and (msg.nick or ours) then
        table.insert(role, 1, {rank_text(irc, msg)})
    end

    line(ctx, win, 'from', from)
    line(ctx, win, 'identity', identity)
    line(ctx, win, 'role', role)
end

-- What became of our own line: the rate limit's delay, and the server's
-- receipt
local function fate(msg)
    local parts = {}
    local delivery = msg.delivery
    if delivery then
        if delivery.state == 'sent' then
            table.insert(parts, {string.format('sent after %.1f s in the queue', delivery.delay)})
        else
            table.insert(parts, {delivery.state, draw.yellow})
        end
    end
    local receipt = msg.receipt
    if receipt then
        local color = receipt == 'received' and draw.green or receipt == 'rejected' and draw.red or draw.yellow
        local text = receipt
        if msg.rejection then text = text .. ': ' .. scrub(msg.rejection) end
        table.insert(parts, {text, color})
    end
    return parts
end

-- Summaries, by command ==============================================

local summaries = {}

-- A PRIVMSG or NOTICE between users or to a channel: who sent it, how,
-- and the text
local function chat_summary(ctx, win, msg)
    local irc = net_irc(ctx)
    local prefix = msg.statusmsg
    local target = (msg[1] or ''):sub(#(prefix or '') + 1)
    local channel = irc and irc_model.is_channel_name(irc, target)
        or not irc and target:match '^[#&]' ~= nil

    sender(ctx, irc, win, msg, channel)

    local text = msg[2] or ''
    local ctcp, args = text:match '^\x01([^\x01 ]+) ?([^\x01]*)\x01?$'
    local kind
    if ctcp == 'ACTION' then
        kind, text = 'action', args
    elseif ctcp then
        kind, text = 'CTCP ' .. scrub(ctcp) .. (msg.command == 'NOTICE' and ' reply' or ''), args
    else
        kind = msg.command == 'NOTICE' and 'notice' or 'message'
    end
    local sent = {{kind .. ' to ' .. scrub(target)}}
    if prefix then
        table.insert(sent, {scrub(prefix) .. ' and above only', draw.red})
    end
    table.insert(sent, {'at ' .. scrub(msg.tags.time or msg.time or '?')})
    if msg.history then
        table.insert(sent, {'from history', draw.yellow})
    end
    line(ctx, win, 'sent', sent)
    local parent = tag_value(msg.tags, '+reply')
    if parent then line(ctx, win, 'reply to', {{scrub(parent)}}) end
    line(ctx, win, 'delivery', fate(msg))

    field(win, 'text', chat_width)
    addircstr(win, text, nil, {cols = ctx.cols, indent = chat_width + 2})
    win:waddstr '\n'
end

summaries.PRIVMSG = chat_summary
summaries.NOTICE = chat_summary

-- Topic text under a label, or what stands in for it
local function topic_line(ctx, win, label, topic)
    if topic == nil then
        line(ctx, win, label, {{'not known', draw.yellow}})
    elseif topic == '' then
        line(ctx, win, label, {{'none', draw.yellow}})
    else
        field(win, label, chat_width)
        addircstr(win, topic, nil, {cols = ctx.cols, indent = chat_width + 2})
        win:waddstr '\n'
    end
end

-- A topic change: the new topic and the one it replaced
function summaries.TOPIC(ctx, win, msg)
    sender(ctx, net_irc(ctx), win, msg, true)

    local changed = {{'topic of ' .. scrub(msg[1] or '?')}, {'at ' .. scrub(msg.tags.time or msg.time or '?')}}
    if msg.history then
        table.insert(changed, {'from history', draw.yellow})
    end
    line(ctx, win, 'changed', changed)

    if msg[2] == '' then
        line(ctx, win, 'topic', {{'cleared', draw.yellow}})
    else
        topic_line(ctx, win, 'topic', msg[2])
    end

    local before = msg.topic_before or {}
    topic_line(ctx, win, 'before', before.topic)
    local set = {}
    if before.who then table.insert(set, {'by ' .. scrub(before.who)}) end
    if before.time then
        local ago = math.max(0, os.time() - before.time)
        table.insert(set, {os.date('%Y-%m-%d %H:%M', before.time) .. ', ' .. draw.duration(ago) .. ' ago'})
    end
    line(ctx, win, 'was set', set)
end

-- A server notice: what the parser made of it
local function snotice_summary(_, win, msg)
    field(win, 'from')
    draw.bold(win)
    win:waddstr(scrub(msg.source))
    draw.normal(win)
    win:waddstr(' at ', scrub(msg.tags.time or msg.time or '?'), '\n\n')

    local note = M.decode(msg)
    field(win, 'name')
    draw.magenta(win)
    win:waddstr(note and note.name or '?', '\n')
    draw.normal(win)
    for k, v in tablex.sort(note or {}) do
        if k ~= 'name' then
            field(win, k)
            win:waddstr(scrub(tostring(v)), '\n')
        end
    end
end

-- The summary of a message, or nil
local function summary_of(msg)
    if M.snotice_text(msg) then return snotice_summary end
    return summaries[msg.command]
end

-- The message level ==================================================

local function message_level(win, msg, show_raw)
    if next(msg.tags) then
        draw.blue(win)
        win:waddstr '      tags:'
        for k, v in tablex.sort(msg.tags) do
            draw.cyan(win)
            win:wmove(ncurses.getyx(win), 12)
            win:waddstr(show_raw and rawstr(k) or scrub(k))
            if v == '' or v == true then
                win:waddstr '\n'
            else
                draw.normal(win)
                win:waddstr ': '
                win:waddstr(show_raw and rawstr(v) or scrub(v), '\n')
            end
        end
    end

    if msg.source then
        field(win, 'source')
        win:waddstr(scrub(msg.source), '\n')
    end

    delivery_fields(win, msg)

    field(win, 'command')
    local cmd_color = M.palette[msg.command]
    if cmd_color then cmd_color(win) end
    draw.bold(win)
    win:waddstr(scrub(tostring(msg.command)))
    draw.bold_(win)
    if not show_raw then
        local name = numeric_names[msg.command]
        if name then
            win:waddstr(' - ', name)
        end
    end
    win:waddstr '\n'

    for i, v in ipairs(msg) do
        draw.blue(win)
        win:waddstr(string.format('%10d: ', i))
        draw.normal(win)
        if show_raw then
            win:waddstr(rawstr(v))
        else
            addircstr(win, v)
        end
        win:waddstr '\n'
    end
end

-- The pane ===========================================================

local levels <const> = {'summary', 'message', 'raw'}

--- The level the detail shows: the one picked, else the summary when
--- there is one.
---@param detail hub.Detail
---@return 'summary'|'message'|'raw'
function M.level(detail)
    return detail.level or (summary_of(detail.data) and 'summary' or 'message')
end

function M.render(ctx, win)
    local detail = ctx.vs
    local msg = detail.data
    local shown = M.level(detail)
    local summary = summary_of(msg)

    for _, level in ipairs(levels) do
        if level ~= 'summary' or summary then
            ctx.add_button(win, '[' .. level .. ']', function() detail.level = level end, level ~= shown)
            win:waddstr ' '
        end
    end
    win:waddstr '\n\n'

    if shown == 'summary' and summary then
        summary(ctx, win, msg)
    else
        message_level(win, msg, shown == 'raw')
    end
end

return M
