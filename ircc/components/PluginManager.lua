--[[

Plugin API:

.name     - string   - name of the plugin
.commands - table    - mapping from command name to argument handlers
.irc      - table    - mapping from IRC commands to functions
.widget   - function - called to render plugin state during /plugins view

]]

local path                <const> = require 'pl.path'
local file                <const> = require 'pl.file'
local pretty              <const> = require 'pl.pretty'
local class               <const> = require 'pl.class'

local M = class()
M._class = 'PluginManager'

function M:_init()
    self.plugins = {}
end

function M:load(base, modules)
    self.base = base
    self.plugins = {}
    for _, plugin_name in ipairs(modules) do
        self:add_plugin(plugin_name)
    end
end

function M:dispatch_irc(irc)
    for _, plugin in pairs(self.plugins) do
        local h = plugin.irc
        if h then
            local success, result = pcall(h, irc)
            if not success then
                status(plugin.name, 'irc handler error: %s', result)
            end
        end
    end
end

function M:find_command(command)
    for _, plugin in pairs(self.plugins) do
        local commands = plugin.commands
        if commands then
            local entry = plugin.commands[command]
            if entry then
                return entry
            end
        end
    end
end

function M:plugin_path(name, ext)
    return path.join(self.base, name .. '.' .. ext)
end

function M:add_plugin(plugin_name)
    local plugin_path = self:plugin_path(plugin_name, 'lua')
    local plugin, load_error = loadfile(plugin_path)

    local state_path = self:plugin_path(plugin_name, 'dat')
    local state_body = file.read(state_path)
    local state = state_body and pretty.read(state_body)

    local function save(new_state)
        file.write(state_path, pretty.write(new_state))
    end

    if plugin then
        local started, result = pcall(plugin, state, save)
        if started then
            self.plugins[plugin_name] = result
        else
            status('plugin', 'startup: %s', result)
        end
    else
        status('plugin', 'loadfile: %s', load_error)
    end
end

function M:plugin_list()
    local result = {}
    for script_name, plugin in pairs(self.plugins) do
        table.insert(result, plugin.name or script_name)
    end
    return result
end

return M
