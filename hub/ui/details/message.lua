-- An IRC message in the detail pane, at one of three levels, which the
-- buttons at the top switch between: a summary of what it means, for a
-- command that has one; the message as the server sent it (tags, source,
-- our delivery and the server's receipt, command and arguments); and that
-- with its strings escaped. It opens at the summary when there is one.
-- Also the command colors and notice matching the console shares.

local addircstr   <const> = require 'hub.ui.irc_formatting'
local draw        <const> = require 'hub.ui.draw'
local hybrid      <const> = require 'hub.ui.details.hybrid'
local irc_model   <const> = require 'hub.net.irc'
local ircd        <const> = require 'hub.net.ircd'
local notice      <const> = require 'hub.features.snotice.notice'
local numerics    <const> = require 'hub.lib.numerics'
local scrub       <const> = require 'hub.lib.scrub'
local solanum     <const> = require 'hub.ui.details.solanum'
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

--- The name of a numeric on a network, or nil.
---@param net string|nil
---@param command string|integer
---@return string|nil
function M.numeric_name(net, command)
    return ircd.numeric_names(net)[command]
end

--- The color of a command on a network, or nil.
---@param net string|nil
---@param command string|integer
function M.color(net, command)
    local name = M.numeric_name(net, command)
    if name and name:sub(1, 4) == 'ERR_' then return draw.red end
    return M.palette[command]
end

-- What a network's replies mean: ui/details/solanum.lua or hybrid.lua
local meanings <const> = {
    [ircd.SOLANUM] = solanum,
    [ircd.HYBRID] = hybrid,
}

local function meaning(net)
    return meanings[ircd.of(net)]
end

--- The body of a server notice on a network, without its header, or nil.
---@param net string|nil
---@param msg hub.Message
function M.snotice_text(net, msg)
    return notice.text(net, msg)
end

--- The parsed form of a server notice on a network (without the time,
--- which the message shows), or nil for any other message.
---@param net string|nil
---@param msg hub.Message
function M.decode(net, msg)
    return notice.parse(net, msg)
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
    local name = M.numeric_name(detail.net, msg.command)
    return string.format('message %s%s', scrub(tostring(msg.command)), name and ' ' .. name or '')
end

-- Shared parts ======================================================

-- The protocol model of the detail's network, nil while it is idle
local function net_irc(ctx)
    local rec = ctx.net and HUB.state.nets[ctx.net]
    return rec and rec.irc
end

-- A label in the label column, `width` wide (10, the message level's, by
-- default), leaving the color normal for its value
local function field(win, label, width)
    draw.blue(win)
    win:waddstr(string.format('%' .. (width or 10) .. 's: ', label))
    draw.normal(win)
end

-- What the rate limit did with our line, and its color; nil when it never
-- held it back
local function delivery_text(msg)
    local delivery = msg.delivery
    if not delivery then return nil end
    if delivery.state == 'sent' then
        return string.format('sent after %.1f s in the queue', delivery.delay)
    end
    return delivery.state, draw.yellow
end

-- The server's receipt of our labeled line, and its color; nil without one
local function receipt_text(msg)
    local receipt = msg.receipt
    if not receipt then return nil end
    local color = receipt == 'received' and draw.green or receipt == 'rejected' and draw.red or draw.yellow
    if msg.rejection then return receipt .. ': ' .. scrub(msg.rejection), color end
    return receipt, color
end

-- Width of a summary's label column
local summary_width <const> = 8

-- A line of a summary: its label, then each part {text, color}, the text
-- scrubbed already, separated by commas, wrapping under the first.
-- Nothing without a part.
local function line(ctx, win, label, parts)
    if #parts == 0 then return end
    field(win, label, summary_width)
    for i, part in ipairs(parts) do
        if part[2] then part[2](win) end
        draw.wrap_text(win, (i > 1 and ' ' or '') .. part[1] .. (i < #parts and ',' or ''),
            ctx.cols, summary_width + 2)
        draw.normal(win)
    end
    win:waddstr '\n'
end

-- Text with its formatting under a label, wrapping under its column
local function formatted(ctx, win, label, text)
    field(win, label, summary_width)
    addircstr(win, text, nil, {cols = ctx.cols, indent = summary_width + 2})
    win:waddstr '\n'
end

-- Text a user gave, such as a reason, unless they gave none
local function reason(ctx, win, label, text)
    if text and text ~= '' then formatted(ctx, win, label, text) end
end

-- Arguments first to last, on one line, unless there are none
local function args_line(ctx, win, msg, first, last)
    if first > last then return end
    local args = {}
    for i = first, last do table.insert(args, scrub(msg[i])) end
    line(ctx, win, 'args', {{table.concat(args, ' ')}})
end

-- Parts that say when a message was sent, after `parts`
local function stamped(parts, msg)
    table.insert(parts, {'at ' .. scrub(msg.tags.time or msg.time or '?')})
    if msg.history then
        table.insert(parts, {'from history', draw.yellow})
    end
    return parts
end

-- Parts that say who set something and when, as far as we know: `time`
-- in epoch seconds
local function set_by(who, time)
    local parts = {}
    if who then table.insert(parts, {'by ' .. scrub(who)}) end
    if time then
        local ago = math.max(0, os.time() - time)
        table.insert(parts, {draw.date('%Y-%m-%d %H:%M', time) .. ', ' .. draw.duration(ago) .. ' ago'})
    end
    return parts
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

-- Who sent the message, on three lines, each left out with nothing to
-- say: where it came from, the identity behind it, and its role (rank in
-- the channel it was sent to, bot, oper). Every summary starts with it.
local function sender(ctx, win, msg)
    local irc = net_irc(ctx)
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
        -- identified means the nick belongs to the account, grouped or not
        local identified = tags['solanum.chat/identified'] ~= nil
        if account then
            table.insert(identity, {'account ' .. scrub(account)})
            if not identified and irc and irc_model.fold(irc, account) ~= irc_model.fold(irc, msg.nick) then
                table.insert(identity, {'not the nick', draw.yellow})
            end
        elseif caps['account-tag'] then
            table.insert(identity, {'not logged in', draw.yellow})
        end
        if identified then
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
    if (msg.nick or ours) and irc and irc_model.sent_to_channel(irc, msg) then
        table.insert(role, 1, {rank_text(irc, msg)})
    end

    line(ctx, win, 'from', from)
    line(ctx, win, 'identity', identity)
    line(ctx, win, 'role', role)
end

-- Summaries, by command, after the sender ============================

local summaries = {}

-- A PRIVMSG or NOTICE between users or to a channel: how it was sent,
-- what became of our own, and the text
local function chat_summary(ctx, win, msg)
    local prefix = msg.statusmsg
    local target = (msg[1] or ''):sub(#(prefix or '') + 1)

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
    if msg.context then
        local channel = tag_value(msg.tags, irc_model.channel_context_tag)
            or tag_value(msg.tags, '+draft/channel-context') or '?'
        table.insert(sent, {'privately, in ' .. scrub(channel), draw.red})
    end
    line(ctx, win, 'sent', stamped(sent, msg))
    local parent = tag_value(msg.tags, '+reply')
    if parent then line(ctx, win, 'reply to', {{scrub(parent)}}) end

    local fate = {}
    for _, part in ipairs {{delivery_text(msg)}, {receipt_text(msg)}} do
        if part[1] then table.insert(fate, part) end
    end
    line(ctx, win, 'delivery', fate)

    formatted(ctx, win, 'text', text)
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
        formatted(ctx, win, label, topic)
    end
end

-- A topic change: the new topic and the one it replaced
function summaries.TOPIC(ctx, win, msg)
    line(ctx, win, 'changed', stamped({{'topic of ' .. scrub(msg[1] or '?')}}, msg))

    if msg[2] == '' then
        line(ctx, win, 'topic', {{'cleared', draw.yellow}})
    else
        topic_line(ctx, win, 'topic', msg[2])
    end

    local before = msg.topic_before or {}
    topic_line(ctx, win, 'before', before.topic)
    line(ctx, win, 'was set', set_by(before.who, before.time))
end

-- Joining a channel: with extended-join, the realname too
function summaries.JOIN(ctx, win, msg)
    line(ctx, win, 'joined', stamped({{scrub(msg[1] or '?')}}, msg))
    reason(ctx, win, 'realname', msg[3])
end

function summaries.PART(ctx, win, msg)
    line(ctx, win, 'left', stamped({{scrub(msg[1] or '?')}}, msg))
    reason(ctx, win, 'reason', msg[2])
end

function summaries.KICK(ctx, win, msg)
    line(ctx, win, 'kicked', stamped({{scrub(msg[2] or '?') .. ' from ' .. scrub(msg[1] or '?')}}, msg))
    reason(ctx, win, 'reason', msg[3])
end

-- A quit reason of two server names is how a netsplit reads
local function netsplit(text)
    return text and text:match '^[%w-]+%.[%w.-]+ [%w-]+%.[%w.-]+$' ~= nil
end

function summaries.QUIT(ctx, win, msg)
    local quit = stamped({}, msg)
    if netsplit(msg[1]) then table.insert(quit, 1, {'netsplit', draw.yellow}) end
    line(ctx, win, 'quit', quit)
    reason(ctx, win, 'reason', msg[1])
    local channels = {}
    for _, name in ipairs(msg.channels or {}) do table.insert(channels, {scrub(name)}) end
    line(ctx, win, 'left', channels)
end

function summaries.NICK(ctx, win, msg)
    line(ctx, win, 'renamed', stamped({{'to ' .. scrub(msg[1] or '?'), draw.bold}}, msg))
end

function summaries.ACCOUNT(ctx, win, msg)
    local account = msg[1]
    local change = account == '*' and {'logged out', draw.yellow}
        or {'logged in as ' .. scrub(account or '?'), draw.green}
    line(ctx, win, 'account', stamped({change}, msg))
end

-- The source holds the old user@host, which `from` shows
function summaries.CHGHOST(ctx, win, msg)
    line(ctx, win, 'host', stamped({{'now ' .. scrub(msg[1] or '?') .. '@' .. scrub(msg[2] or '?'), draw.bold}}, msg))
end

local function wallops_summary(ctx, win, msg)
    line(ctx, win, 'sent', stamped({{msg.command == 'OPERWALL' and 'operwall' or 'wallops'}}, msg))
    formatted(ctx, win, 'text', msg[1] or '')
end

summaries.WALLOPS = wallops_summary
summaries.OPERWALL = wallops_summary

-- The changes of a MODE: {'+' or '-', letter, argument or nil}, each
-- taking its argument by the network's PREFIX and CHANMODES; without
-- `irc`, for user modes, none takes one
local function mode_changes(irc, msg)
    local changes, sign, cursor = {}, '+', 3
    for flag in (msg[2] or ''):gmatch '.' do
        if flag == '+' or flag == '-' then
            sign = flag
        else
            local takes = irc and irc_model.mode_takes_arg(irc, sign, flag)
            local arg
            if takes then
                arg = msg[cursor]
                cursor = cursor + 1
            end
            table.insert(changes, {sign, flag, arg})
        end
    end
    return changes
end

function summaries.MODE(ctx, win, msg)
    local irc = net_irc(ctx)
    local target = msg[1] or '?'
    -- the network's model, for a channel's modes
    local chan_irc = irc and irc_model.is_channel_name(irc, target) and irc or nil
    line(ctx, win, 'changed', stamped({{'modes of ' .. scrub(target)}}, msg))

    for i, change in ipairs(mode_changes(chan_irc, msg)) do
        local sign, flag, arg = change[1], change[2], change[3]
        if i == 1 then
            field(win, 'modes', summary_width)
        else
            win:waddstr(string.rep(' ', summary_width + 2))
        end
        if sign == '+' then draw.green(win) else draw.red(win) end
        win:waddstr(sign, scrub(flag))
        draw.normal(win)
        if arg then win:waddstr(' ', scrub(arg)) end
        local name
        if chan_irc then
            local prefix = chan_irc.mode_to_prefix[flag]
            name = prefix and solanum.prefix_names[prefix] or solanum.mode_names[flag]
        end
        if name then
            draw.blue(win)
            win:waddstr(' ', name)
            draw.normal(win)
        end
        win:waddstr '\n'
    end
end

-- A server notice: what the parser made of it
local function snotice_summary(ctx, win, msg)
    line(ctx, win, 'sent', stamped({{'server notice'}}, msg))
    local note = M.decode(ctx.net, msg)
    line(ctx, win, 'name', {{note and note.name or '?', draw.magenta}})
    for k, v in tablex.sort(note or {}) do
        if k ~= 'name' then line(ctx, win, k, {{scrub(tostring(v))}}) end
    end
end

-- The first line of a numeric's summary: its name and number, whom it
-- is to and when; red for an error
local function reply_header(ctx, win, msg)
    local name = M.numeric_name(ctx.net, msg.command)
    local failed = name and name:sub(1, 4) == 'ERR_'
    local reply = (name or 'numeric') .. string.format(' (%03d)', msg.command)
    if msg[1] then reply = reply .. ' to ' .. scrub(msg[1]) end
    line(ctx, win, failed and 'error' or 'reply', stamped({{reply, failed and draw.red or nil}}, msg))
end

-- An error reply without fields of its own: its arguments, and the text
-- that says what went wrong, which errors end with
local function error_summary(ctx, win, msg)
    reply_header(ctx, win, msg)
    args_line(ctx, win, msg, 2, #msg - 1)
    if #msg > 1 then formatted(ctx, win, 'text', msg[#msg]) end
end

-- A reply's argument, by the kind its field gives it (ui/details/solanum.lua)
local function reply_field(ctx, win, label, kind, value)
    local n = tonumber(value)
    if kind == 'text' then
        formatted(ctx, win, label, value)
    elseif kind == 'time' and n then
        line(ctx, win, label, set_by(nil, n))
    elseif kind == 'secs' and n then
        line(ctx, win, label, {{draw.duration(n)}})
    elseif kind == 'mins' and n then
        line(ctx, win, label, {n == 0 and {'permanent'} or {draw.duration(n * 60) .. ' left'}})
    elseif kind == 'line' then
        local name = meaning(ctx.net).line_types[value]
        line(ctx, win, label, {{name or scrub(value), draw.bold}})
    elseif kind == 'reasons' then
        local public, private = value:match '^(.-)|(.*)$'
        formatted(ctx, win, label, public or value)
        if private and private ~= '' then formatted(ctx, win, 'oper why', private) end
    elseif kind == 'paren' then
        line(ctx, win, label, {{scrub(value:match '^%((.*)%)$' or value)}})
    else
        line(ctx, win, label, {{scrub(value)}})
    end
end

-- A reply with fields (ui/details/solanum.lua): each argument after the
-- target under its label, and any the fields don't name after them
local function reply_summary(ctx, win, msg)
    reply_header(ctx, win, msg)
    local fields = meaning(ctx.net).fields[msg.command]
    local i = 2
    for k, field_spec in ipairs(fields) do
        local label, kind = field_spec:match '^(.-):(%a+)$'
        label = label or field_spec
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
        if label ~= '-' and value and value ~= '' then
            reply_field(ctx, win, label, kind, value)
        end
    end
    args_line(ctx, win, msg, i, #msg)
end

-- An auth block (STATS I, or TESTLINE matching no ban): I <name> <password>
-- <sigils><user>@<host> <port> <class> :<description>
summaries[numerics.RPL_STATSILINE] = function(ctx, win, msg)
    local name, password, mask, port, class = msg[3], msg[4], msg[5] or '', msg[6], msg[7]
    local meant = meaning(ctx.net)

    -- the flags are the sigils before the user, which the network's
    -- auth_flags name
    local sigils = {}
    for sigil in pairs(meant.auth_flags) do table.insert(sigils, '%' .. sigil) end
    local prefix, user, host = mask:match('^([' .. table.concat(sigils) .. ']*)([^@]*)@(.*)$')
    if not prefix then prefix, user, host = '', mask, nil end
    local flags, spoof = {}, false
    for sigil in prefix:gmatch '.' do
        table.insert(flags, {meant.auth_flags[sigil] .. ' (' .. sigil .. ')'})
        if sigil == '=' then spoof = true end
    end

    local block = {{scrub(user) .. '@' .. (host == '255.255.255.255' and '(hidden)' or scrub(host or '?')), draw.bold}}
    if class then table.insert(block, {'class ' .. scrub(class)}) end
    line(ctx, win, 'auth', stamped(block, msg))
    line(ctx, win, 'flags', flags)
    if name and spoof then
        -- hybrid gives * for a block without a spoof name
        if name ~= '*' then line(ctx, win, 'spoof', {{scrub(name)}}) end
    elseif meant.auth_redirects and name and name ~= 'NOMATCH' and name ~= '<NULL>' then
        line(ctx, win, 'redirect', {{scrub(name) .. (port and port ~= '0' and ' port ' .. scrub(port) or '')}})
    end
    if meant.auth_passwords and password and password ~= '<NULL>' then
        line(ctx, win, 'password', {{password == '*' and '(hidden)' or scrub(password)}})
    end
    if #msg > 7 then reason(ctx, win, 'desc', msg[#msg]) end
end

-- The summary of a message, or nil
local function summary_of(net, msg)
    if M.snotice_text(net, msg) then return snotice_summary end
    if summaries[msg.command] then return summaries[msg.command] end
    if meaning(net).fields[msg.command] then return reply_summary end
    local name = M.numeric_name(net, msg.command)
    if name and name:sub(1, 4) == 'ERR_' then return error_summary end
end

-- The message level ==================================================

local function message_level(net, win, msg, show_raw)
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

    for _, row in ipairs {{'delivery', delivery_text(msg)}, {'receipt', receipt_text(msg)}} do
        if row[2] then
            field(win, row[1])
            if row[3] then row[3](win) end
            win:waddstr(row[2], '\n')
            draw.normal(win)
        end
    end

    field(win, 'command')
    local cmd_color = M.color(net, msg.command)
    if cmd_color then cmd_color(win) end
    draw.bold(win)
    win:waddstr(scrub(tostring(msg.command)))
    draw.bold_(win)
    if not show_raw then
        local name = M.numeric_name(net, msg.command)
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
    return detail.level or (summary_of(detail.net, detail.data) and 'summary' or 'message')
end

function M.render(ctx, win)
    local detail = ctx.vs
    local msg = detail.data
    local shown = M.level(detail)
    local summary = summary_of(ctx.net, msg)

    for _, level in ipairs(levels) do
        if level ~= 'summary' or summary then
            ctx.add_button(win, '[' .. level .. ']', function() detail.level = level end, level ~= shown)
            win:waddstr ' '
        end
    end
    win:waddstr '\n\n'

    if shown == 'summary' and summary then
        sender(ctx, win, msg)
        summary(ctx, win, msg)
    else
        message_level(ctx.net, win, msg, shown == 'raw')
    end
end

return M
