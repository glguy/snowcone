local M = {
    title = 'plugins',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    green()
    addstr('          -= plugins =-\n')
    normal()

    for script_name, plugin in pairs(plugins) do
        local name = plugin.name or script_name

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

    draw_global_load()
end

return M
