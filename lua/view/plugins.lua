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

        local widgets = plugin.widgets
        if widgets ~= nil then
            for _, entry in ipairs(widgets) do
                addstr('    ')
                if type(entry) == 'function' then
                    local success, result = pcall(entry)
                    if success then
                        normal()
                    else
                        red()
                        addstr(tostring(result))
                    end
                elseif type(entry) == 'table' then
                    entry = pretty.write(entry)
                    entry = entry:gsub('\n', '\n    ')
                    addstr('    ' .. entry)
                else
                    entry = tostring(entry)
                    entry = entry:gsub('\n', '\n    ')
                    addstr('    ' .. entry)
                end
                addstr '\n'
            end
        end
    end

    draw_global_load('cliconn', conn_tracker)
end

return M
