local pretty = require 'pl.pretty'

local M = {
    title = 'stats',
    keypress = function() end,
    draw_status = function() end,
}

local function list_stats(win, name, data)
    win:waddstr(string.format('%-20s %10d %10d ', name, data.n, data.max))
    add_button(win, '[CLEAR]', function() data:reset() end)
    win:waddstr '\n'
end


function M:render(win)

    local function label(txt)
        win:waddstr(string.format('%14s: ', txt))
    end

    green(win)
    win:waddstr('          -= stats =-\n')
    normal(win)

    win:waddstr '\n'

    label 'Lua version'
    bold(win)
    win:waddstr(_VERSION)
    bold_(win)
    win:waddstr '\n'

    label 'Lua memory'
    bold(win)
    win:waddstr(string.format('%-10s ', pretty.number(collectgarbage 'count' * 1024, 'M')))
    bold_(win)
    add_button(win, '[GC]', function() collectgarbage() end)
    win:waddstr '\n'

    label 'Uptime'
    bold(win)
    win:waddstr(uptime)
    bold_(win)
    win:waddstr '\n'

    label 'Idle'
    bold(win)
    win:waddstr(irc_state and (uptime - irc_state.liveness) or 'N/A')
    bold_(win)
    win:waddstr '\n'

    label 'Tasks'
    bold(win)
    for task, _ in pairs(client_tasks) do
        win:waddstr(task.name or task, ' ')
    end
    bold_(win)
    win:waddstr '\n'

    label 'Plugins'
    bold(win)
    for _, name in ipairs(plugin_manager:plugin_list()) do
        win:waddstr(name, ' ')
    end
    bold_(win)
    win:waddstr '\n'

    win:waddstr '\n'

    green(win)

    win:waddstr('dataset                      .n       .max\n')

    normal(win)
    list_stats(win, '/console', messages)
    list_stats(win, '/status', status_messages)
    list_stats(win, '/list', channel_list)

    for _, buffer in pairs(buffers) do
        list_stats(win, buffer.name, buffer.messages)
    end

    win:waddstr '\n'
end

return M
