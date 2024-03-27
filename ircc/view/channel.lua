local tablex = require 'pl.tablex'
local irc_formatting = require 'utils.irc_formatting'
local drawing = require 'utils.drawing'
local OrderedMap = require 'components.OrderedMap'

local M = {
    title = 'session',
    keypress = function() end,
    draw_status = function() end,
}

local function render_entry(entry)
    cyan()
    addstr(entry.label)
    addstr ': '
    normal()
    irc_formatting(entry.value)
    
end

local function build_entries(entries)
    local function line(k,v) entries:insert(true, {label = k, value = v}) end

    if not irc_state then
        line('Status', 'Not connected')
        return
    end

    if not talk_target then
        line('Status', 'No target')
        return
    end

    if irc_state:is_channel_name(talk_target) then

        local channel = irc_state:get_channel(talk_target)
        if not channel then
            line('Channel', talk_target)
            return
        end

        line('Channel', channel.name)
        if channel.topic then
            line('Topic', channel.topic)
        end
        if channel.creationtime then
            line('Created', channel.creationtime) -- prettier
        end
        if channel.modes then
            
        end
    else
        local user = irc_state:get_user(talk_target)

        if not user then
            line('Nickname', talk_target)
            return
        end

        line('Nickname', user.nick)
        
        if user.away then
            line('Away', user.away)
        end    
    end
end

function M:render()
    
    local entries = OrderedMap(1000, function(x) return x end)
    build_entries(entries)
    local rows = math.max(0, tty_height - 2)
    drawing.draw_rotation(1, rows, entries, function() return true end, render_entry) 
end

return M
