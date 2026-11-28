-- The accept list (hub.AcceptList, features/queries/accept.lua) in the
-- detail pane: the nicks as the server last sent them, with how long ago,
-- each with [x] to take it off. [↻] asks for the list again; taking a nick
-- off does too, and shows the list as it is then. The filter (Ctrl-S,
-- /filter) shows only the nicks that match.

local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local matching  <const> = require 'hub.lib.matching'
local queries   <const> = require 'hub.features.queries'
local scrub     <const> = require 'hub.lib.scrub'

local M = {kind = 'accept', filter = true}

M.events = {
    ['query.accept'] = function(ev) return ev.net, ev.accept end,
}

function M.title(detail)
    local n = #detail.data.nicks
    return string.format('accept list (%d %s)', n, n == 1 and 'nick' or 'nicks')
end

function M.render(ctx, win)
    ---@type hub.AcceptList
    local list = ctx.vs.data
    local pattern = control.filter(ctx.id)

    win:waddstr(string.format('%d %s, as of %s ago ', #list.nicks, #list.nicks == 1 and 'nick' or 'nicks',
        draw.duration(os.time() - list.at)))
    ctx.add_chip(win, '↻', function() queries.accept(ctx.net, {}) end)
    win:waddstr '\n'

    local shown = 0
    for _, nick in ipairs(list.nicks) do
        if not pattern or matching.safematch(nick, pattern) then
            shown = shown + 1
            ctx.add_chip(win, 'x', function() queries.accept(ctx.net, {'-' .. nick}) end, 'danger')
            win:waddstr(' ', scrub(nick), '\n')
        end
    end
    if pattern then
        if shown > 0 then win:waddstr '\n' end
        draw.yellow(win)
        win:waddstr(string.format('%d of %d %s match\n', shown, #list.nicks, #list.nicks == 1 and 'nick' or 'nicks'))
        draw.normal(win)
    end
end

return M
