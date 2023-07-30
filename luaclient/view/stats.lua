local pretty = require 'pl.pretty'

local M = {
    title = 'stats',
    keypress = function() end,
    draw_status = function() end,
}

local function list_stats(name, data)
    addstr(string.format('%10s %10d %10d\n', name, data.n, data.max))
end


function M:render()
    green()
    addstr('          -= stats =-\n')
    normal()

    addstr '\n'

    addstr('Lua version:  ')
    bold()
    addstr(_VERSION)
    bold_()
    addstr '\n'

    addstr('OSSL version: ')
    local has_openssl, openssl = pcall(require, 'openssl')
    bold()
    if has_openssl then
        local lib_version, _, ossl_version = openssl.version()
        addstr(lib_version .. ' / ' .. ossl_version)
    else
        red()
        addstr('none')
    end
    normal()
    addstr '\n'

    addstr("Lua memory:   ")
    bold()
    addstr(string.format('%-10s ', pretty.number(collectgarbage 'count' * 1024, 'M')))
    bold_()
    add_button('[GC]', function() collectgarbage() end)
    addstr '\n'

    addstr('Uptime:       ')
    bold()
    addstr(uptime)
    bold_()
    addstr '\n'

    addstr('Idle:         ')
    bold()
    addstr(uptime - liveness)
    bold_()
    addstr '\n'

    addstr('Plugins:      ')
    bold()
    local first_plugin = true
    for script_name, plugin in pairs(plugins) do
        if first_plugin then
            first_plugin = false
        else
            bold_()
            addstr(', ')
            bold()
        end
        addstr(plugin.name or script_name)
    end
    bold_()
    addstr '\n'

    addstr '\n'

    green()
    addstr('   dataset         .n       .max\n')

    normal()
    list_stats('messages', messages)
    list_stats('status', status_messages)

    addstr '\n'

    draw_global_load()
end

return M
