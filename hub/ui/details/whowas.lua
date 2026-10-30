-- A WHOWAS reply (hub.Whowas, features/chat/whowas.lua) in the detail
-- pane: each past entry the server keeps, newest first. The filter
-- (Ctrl-S, /filter) shows only the entries with a field that matches.

local addircstr <const> = require 'hub.ui.irc_formatting'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local fields    <const> = require 'hub.ui.fields'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key

local M = {kind = 'whowas', filter = true}

function M.title(detail)
    local n = #detail.data.entries
    return string.format('whowas %s (%d %s)', scrub(detail.data.nick), n, n == 1 and 'entry' or 'entries')
end

local function text(win, value)
    win:waddstr(value and scrub(tostring(value)) or '-')
end

-- Every field of an entry, for the filter
local function haystack(e)
    local parts = {}
    for _, k in ipairs {'nick', 'user', 'host', 'gecos', 'server', 'signoff', 'account', 'ip', 'org'} do
        if e[k] then table.insert(parts, tostring(e[k])) end
    end
    if e.asn then table.insert(parts, 'AS' .. e.asn) end
    return table.concat(parts, ' ')
end

function M.render(ctx, win)
    ---@type hub.Whowas
    local w = ctx.vs.data
    local pattern = control.filter(ctx.id)

    local shown = 0
    for _, e in ipairs(w.entries) do
        if pattern and not matching.safematch(haystack(e), pattern) then goto continue end
        shown = shown + 1
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
        ::continue::
    end
    if pattern then
        if shown > 0 then win:waddstr '\n' end
        draw.yellow(win)
        win:waddstr(string.format('%d of %d %s match\n', shown, #w.entries,
            #w.entries == 1 and 'entry' or 'entries'))
        draw.normal(win)
    end
end

return M
