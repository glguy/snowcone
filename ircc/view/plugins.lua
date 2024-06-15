local M = {
    title = 'plugins',
    keypress = function() end,
    draw_status = function() end,
}

function M:render(win)
    green(win)
    win:waddstr('          -= plugins =-\n')
    normal(win)

    for script_name, plugin in pairs(plugin_manager.plugins) do
        local name = plugin.name or script_name

        normal(win)
        bold(win)
        win:waddstr(name .. '\n')
        normal(win)

        local widget = plugin.widget
        if widget ~= nil then
            local success, result = pcall(widget, win)
            if success then
                normal(win)
            else
                red(win)
                win:waddstr(tostring(result))
            end
        end
    end
end

return M
