-- /list results of the current network.

local addircstr  <const> = require 'hub.ui.irc_formatting'
local chat       <const> = require 'hub.features.chat'
local common     <const> = require 'hub.features.common'
local control    <const> = require 'hub.ui.control'
local draw       <const> = require 'hub.ui.draw'
local matching   <const> = require 'hub.lib.matching'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local scrub      <const> = require 'hub.lib.scrub'

local function draw_entry(win, entry)
    draw.green(win)
    win:waddstr(' ', scrub(entry.channel))
    draw.blue(win)
    win:waddstr(' ', tostring(entry.users or '?'), ' ')
    draw.normal(win)
    addircstr(win, entry.topic)
end

return {
    id = 'list',
    title = 'list',
    scope = 'net',
    feature = 'chat',
    command = false, -- the chat feature's /list fetches and shows it

    render = function(ctx, win)
        if not (ctx.net and common.enabled(ctx.net, 'chat')) then
            win:waddstr 'The current network does not have the chat feature\n'
            return
        end
        local C = chat.get(ctx.net)
        draw.magenta(win)
        draw.bold(win)
        win:waddstr('         channels: ', tostring(OrderedMap.size(C.list)), ' ')
        ctx.add_button(win, '[REFRESH]', function() chat.list(ctx.net) end)
        draw.bold_(win)

        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(entry)
                return matching.safematch(entry.channel, pattern)
                    or matching.safematch(tostring(entry.users), pattern)
                    or matching.safematch(entry.topic, pattern)
            end
        end
        draw.draw_rotation(win, ctx.vs, 1, math.max(0, ctx.rows - 1), C.list, show, draw_entry)
    end,
}
