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

        bold()
        addstr(name .. '\n')
        normal()

        local widgets = plugin.widgets
        if widgets ~= nil then
            for _, entry in ipairs(widgets) do

                if type(entry) == 'function' then
                    local success, result = pcall(entry)
                    if success then
                        green()
                    else
                        red()
                    end
                    entry = result
                end

                if type(entry) == 'table' then
                    entry = pretty.write(entry)
                else
                    entry = tostring(entry)
                end

                entry = entry:gsub('\n', '\n    ')
                addstr('    ' .. entry .. '\n')
            end
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
