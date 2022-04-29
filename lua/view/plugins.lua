local pretty = require 'pl.pretty'

local M = {
    title = 'plugins',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    green()
    addstr('          -= plugins =-\n')
    normal()

    for i, plugin in ipairs(plugins) do
        local name = plugin.name or '#' .. tostring(i)

        normal()
        bold()
        addstr(name .. '\n')
        normal()

        local widget = plugin.widget
        if widget ~= nil then
            local success, result = pcall(widget)
            if success then
                normal()
            else
                red()
                addstr(tostring(result))
            end
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
