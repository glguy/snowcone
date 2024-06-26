--[[

Plugin API:

.name     - string   - name of the plugin
.commands - table    - mapping from command name to argument handlers
.irc      - table    - mapping from IRC commands to functions
.widget   - function - called to render plugin state during /plugins view

]]

local path = require 'pl.path'
local file = require 'pl.file'
local pretty = require 'pl.pretty'

local M = {}

function M.startup()
    plugins = {}
    if configuration.plugins and configuration.plugins.modules then
        for _, plugin_name in ipairs(configuration.plugins.modules) do
            M.add_plugin(plugin_name)
        end
    end
end

function M.plugin_path(name, ext)
    local base =
        configuration.plugins and
        configuration.plugins.directory or
        path.join(config_dir, 'plugins')
    return path.join(base, name .. '.' .. ext)
end

function M.add_plugin(plugin_name)
    local plugin_path = M.plugin_path(plugin_name, 'lua')
    local plugin, load_error = loadfile(plugin_path)

    local state_path = M.plugin_path(plugin_name, 'dat')
    local state_body = file.read(state_path)
    local state = state_body and pretty.read(state_body)

    local function save(new_state)
        file.write(state_path, pretty.write(new_state))
    end

    if plugin then
        local started, result = pcall(plugin, state, save)
        if started then
            plugins[plugin_name] = result
        else
            status('plugin', 'startup: %s', result)
        end
    else
        status('plugin', 'loadfile: %s', load_error)
    end
end

return M
