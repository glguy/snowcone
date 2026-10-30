-- A WHOWAS reply (hub.Whowas, features/chat/whowas.lua) in the detail
-- pane: each past entry the server keeps, newest first.

local addircstr <const> = require 'hub.ui.irc_formatting'
local draw      <const> = require 'hub.ui.draw'
local fields    <const> = require 'hub.ui.fields'
local scrub     <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key

local M = {kind = 'whowas'}

function M.title(detail)
    local n = #detail.data.entries
    return string.format('whowas %s (%d %s)', scrub(detail.data.nick), n, n == 1 and 'entry' or 'entries')
end

local function text(win, value)
    win:waddstr(value and scrub(tostring(value)) or '-')
end

function M.render(ctx, win)
    ---@type hub.Whowas
    local w = ctx.vs.data

    for _, e in ipairs(w.entries) do
        heading(win, string.format('%s!%s@%s', scrub(e.nick), scrub(e.user or '?'), scrub(e.host or '?')))

        label(win, 'gecos')
        addircstr(win, e.gecos or '')
        win:waddstr '\n'

        label(win, 'account')
        if e.account then
            draw.cyan(win)
            text(win, e.account)
            draw.normal(win)
        else
            text(win, nil)
        end
        win:waddstr '\n'

        if e.ip then
            label(win, 'ip')
            text(win, e.ip)
            key(win, 'asn')
            text(win, e.asn and 'AS' .. e.asn)
            key(win, 'org')
            text(win, e.org)
            win:waddstr '\n'
        end

        label(win, 'server')
        text(win, e.server)
        key(win, 'signoff')
        text(win, e.signoff)
        win:waddstr '\n'
    end
end

return M
