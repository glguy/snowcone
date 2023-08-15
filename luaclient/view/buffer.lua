local tablex = require 'pl.tablex'

local addircstr = require_ 'utils.irc_formatting'
local drawing = require 'utils.drawing'

local function render_irc(irc)
    local command = irc.command
    local source = irc.source:match '^(.-)([.!])' or irc.source
    local action = irc[2]:match '^\x01ACTION (.*)\x01$'
    local text = action or irc[2]

    if source == '>>>' then
        red()
    elseif action then
        blue()
    elseif command == 'PRIVMSG' then
        cyan()
    elseif command == 'NOTICE' then
        green()
    end

    addstr(string.format(' %16.16s ', source))
    addircstr(text)
end

local M = {
    active = true,
    title = 'buffer',
}

local keys = {
    [-ncurses.KEY_PPAGE] = function()
        local elts = math.min(messages.max, messages.n)
        scroll = scroll + math.max(1, tty_height - 2)
        scroll = math.min(scroll, elts - tty_height + 2)
        scroll = math.max(scroll, 0)
    end,
    [-ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 1)
        scroll = math.max(scroll, 0)
    end,
    [string.byte('t')] = function()
        if talk_target ~= nil then
            editor:reset()
            input_mode = 'talk'
        end
    end,
}

function M:keypress(key)
    local h = keys[key]
    if h then
        h()
        draw()
    end
end

local function draw_messages()
    local buffer = buffers[snowcone.irccase(talk_target)]
    if not buffer then return end

    local current_filter
    if input_mode == 'filter' then
        current_filter = editor.rendered
    else
        current_filter = filter
    end

    local show_irc
    if current_filter then
        show_irc = function(irc)
            local haystack
            local source = irc.source
            if source then
                haystack = source .. ' ' .. irc.command .. ' ' .. table.concat(irc, ' ')
            else
                haystack = irc.command .. ' ' .. table.concat(irc, ' ')
            end

            local ok, match = pcall(string.match, haystack, current_filter)
            return not ok or match
        end
    end

    local start = ncurses.getyx()
    local rows = math.max(0, tty_height - 1 - start)
    drawing.draw_rotation(start, rows, buffer, show_irc, render_irc)
end

function M:render()
    draw_messages()
    draw_global_load()
end

function M:draw_status()
    if talk_target then
        green()
        addstr(talk_target .. '')
        normal()
    end

    for k, v in tablex.sort(buffers) do
        if v.seen < v.n then
            red()
            addstr(k:lower() .. '')
        end
    end
end

return M
