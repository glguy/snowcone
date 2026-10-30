-- An IRC message in the detail pane: tags, source, our delivery and the
-- server's receipt, command and arguments, and for a server notice the
-- parsed fields. Meta-R shows the values raw. Also the command colors and
-- notice matching the console shares.

local addircstr   <const> = require 'hub.ui.irc_formatting'
local draw        <const> = require 'hub.ui.draw'
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

-- Names of numerics
local numeric_names = {}
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

function M.modes(detail)
    return {detail.show_raw and 'raw' or nil}
end

function M.keypress(ctx, key)
    if key == -string.byte 'r' then
        ctx.vs.show_raw = not ctx.vs.show_raw
        return true
    end
end

function M.render(ctx, win)
    local msg = ctx.vs.data
    local show_raw = ctx.vs.show_raw

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
        draw.blue(win)
        win:waddstr '    source: '
        draw.normal(win)
        win:waddstr(scrub(msg.source), '\n')
    end

    local delivery = msg.delivery
    if delivery then
        draw.blue(win)
        win:waddstr '  delivery: '
        draw.normal(win)
        if delivery.state == 'sent' then
            win:waddstr(string.format('sent after %.1f s in the queue\n', delivery.delay))
        else
            win:waddstr(delivery.state, '\n')
        end
    end

    local receipt = msg.receipt
    if receipt then
        draw.blue(win)
        win:waddstr '   receipt: '
        draw.normal(win)
        win:waddstr(receipt)
        if msg.rejection then
            win:waddstr(': ', scrub(msg.rejection))
        end
        win:waddstr '\n'
    end

    draw.blue(win)
    win:waddstr '   command: '
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

    -- a server notice also shows what the parser made of it
    local note = M.decode(msg)
    if note then
        win:waddstr '\n'
        draw.blue(win)
        win:waddstr(string.format('%10s: ', 'name'))
        draw.magenta(win)
        win:waddstr(note.name, '\n')
        for k, v in tablex.sort(note) do
            if k ~= 'name' then
                draw.blue(win)
                win:waddstr(string.format('%10s: ', k))
                draw.normal(win)
                win:waddstr(show_raw and rawstr(tostring(v)) or scrub(tostring(v)), '\n')
            end
        end
    end
end

return M
