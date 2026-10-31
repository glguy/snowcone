-- A WHOIS reply (hub.Whois, features/chat/whois.lua) in the detail pane.

local addircstr <const> = require 'hub.ui.irc_formatting'
local draw      <const> = require 'hub.ui.draw'
local fields    <const> = require 'hub.ui.fields'
local scrub     <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key
local words   <const> = fields.words

local M = {kind = 'whois'}

M.events = {
    ['chat.whois'] = function(ev) return ev.net, ev.whois end,
}

function M.title(detail)
    return 'whois ' .. scrub(detail.data.nick)
end

local function text(win, value)
    win:waddstr(value and scrub(tostring(value)) or '-')
end

function M.render(ctx, win)
    ---@type hub.Whois
    local w = ctx.vs.data

    heading(win, string.format('%s!%s@%s', scrub(w.nick), scrub(w.user or '?'), scrub(w.host or '?')))

    label(win, 'gecos')
    addircstr(win, w.gecos or '')
    win:waddstr '\n'

    label(win, 'account')
    if w.account then
        draw.cyan(win)
        text(win, w.account)
        draw.normal(win)
    else
        text(win, nil)
    end
    if w.operator then
        key(win, 'operator')
        draw.red(win)
        text(win, w.operator)
        draw.normal(win)
        key(win, 'privset')
        text(win, w.privset)
    end
    if w.helpop then
        key(win, 'helpop')
        win:waddstr 'yes'
    end
    win:waddstr '\n'

    if w.mask then
        label(win, 'mask')
        text(win, w.mask)
        key(win, 'ip')
        text(win, w.ip)
        key(win, 'asn')
        text(win, w.asn and 'AS' .. w.asn)
        key(win, 'org')
        text(win, w.org)
        win:waddstr '\n'
    end

    label(win, 'secure')
    win:waddstr(w.secure and 'yes' or 'no')
    if w.certfp then
        key(win, 'certfp')
        text(win, w.certfp)
    end
    win:waddstr '\n'

    label(win, 'channels')
    local channels = {}
    for i, channel in ipairs(w.channels) do channels[i] = scrub(channel) end
    words(ctx, win, 'channels', channels, function(win_, name)
        -- operators and voiced users stand out
        local prefix = name:match '^[^#&]*'
        if prefix:find '@' then draw.green(win_)
        elseif prefix ~= '' then draw.yellow(win_) end
    end)

    if w.idle then
        label(win, 'idle')
        win:waddstr(draw.duration(w.idle))
        key(win, 'since')
        win:waddstr(os.date('%c', w.at - w.idle))
        win:waddstr '\n'
    end
    if w.signon then
        label(win, 'signon')
        win:waddstr(os.date('%c', w.signon))
        key(win, 'ago')
        win:waddstr(draw.duration(w.at - w.signon), '\n')
    end

    if w.away then
        label(win, 'away')
        addircstr(win, w.away)
        win:waddstr '\n'
    end

    for _, special in ipairs(w.specials) do
        label(win, 'special')
        addircstr(win, special)
        win:waddstr '\n'
    end

    label(win, 'server')
    text(win, w.server)
    if w.server_info then
        win:waddstr '  '
        addircstr(win, w.server_info)
    end
    win:waddstr '\n'
end

return M
