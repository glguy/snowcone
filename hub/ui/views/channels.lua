-- New channels, flooders and spambots. /list results are the list view.

local control   <const> = require 'hub.ui.control'
local dashboard <const> = require 'hub.ui.dashboard'
local draw      <const> = require 'hub.ui.draw'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'
local stores    <const> = require 'hub.features.snotice.stores'

local CREATE, FLOODER, SPAMBOT <const> = stores.CREATE, stores.FLOODER, stores.SPAMBOT

local function draw_entry(win, entry)
    draw.green(win)
    win:waddstr(string.format(' %-16.16s', scrub(entry.nick)))

    local channels, flags = entry.channels, entry.flags
    local n = #channels
    local limit = 5
    local skipped = math.max(0, n - limit)

    -- older channels are only counted
    if skipped > 0 then
        local creates, floods, spambots = 0, 0, 0
        for i = 1, skipped do
            if flags[i] & CREATE ~= 0 then creates = creates + 1 end
            if flags[i] & FLOODER ~= 0 then floods = floods + 1 end
            if flags[i] & SPAMBOT ~= 0 then spambots = spambots + 1 end
        end
        if creates > 0 then draw.yellow(win) win:waddstr(' ' .. creates .. '*') end
        if floods > 0 then draw.red(win) win:waddstr(' ' .. floods .. '†') end
        if spambots > 0 then draw.white(win) win:waddstr(' ' .. spambots .. '◆') end
    end

    for i = skipped + 1, n do
        local flag = flags[i]
        draw.cyan(win)
        win:waddstr(' ' .. scrub(channels[i]))
        if flag & CREATE ~= 0 then draw.yellow(win) win:waddstr '*' end
        if flag & FLOODER ~= 0 then draw.red(win) win:waddstr '†' end
        if flag & SPAMBOT ~= 0 then draw.white(win) win:waddstr '◆' end
    end
end

return {
    id = 'channels',
    title = 'channels',
    scope = 'net',
    feature = 'snotice',

    render = function(ctx, win)
        local S = dashboard.stores(ctx, win)
        if not S then return end

        draw.magenta(win)
        draw.bold(win)
        win:waddstr 'time     nickname         channels ('
        draw.yellow(win)
        win:waddstr ' * create'
        draw.red(win)
        win:waddstr ' † flood'
        draw.white(win)
        win:waddstr ' ◆ spambot'
        draw.magenta(win)
        win:waddstr ' )'
        draw.normal(win)

        local pattern = control.filter(ctx.id)
        local show
        if pattern then
            show = function(entry)
                if matching.safematch(entry.nick, pattern) then return true end
                for _, c in ipairs(entry.channels) do
                    if matching.safematch(c, pattern) then return true end
                end
                return false
            end
        end
        draw.draw_rotation(win, ctx.vs, 1, math.max(1, ctx.rows - 1), S.new_channels, show, draw_entry)
    end,

    status = function(ctx, win)
        dashboard.load_status(ctx, win, 'cliconn', 'conn')
    end,
}
