-- Reading and validating configuration.
--
-- The result is plain data:
--   {file, dir, warnings, ui, plugins, notifications, mention,
--    networks = {{id, features = {[name] = true}, ...}, ...}}
-- Secrets stay as configured (strings, {command=}, {file=}, {prompt=});
-- they are resolved at connect time by runtime/secrets.lua.

local app     <const> = require 'pl.app'
local file    <const> = require 'pl.file'
local lexer   <const> = require 'pl.lexer'
local path    <const> = require 'pl.path'
local tablex  <const> = require 'pl.tablex'
local schema  <const> = require 'hub.lib.schema'
local cschema <const> = require 'hub.runtime.config_schema'

local M = {}

--- Directory holding configuration, plugins and saved data.
function M.config_dir()
    local config_home = os.getenv 'XDG_CONFIG_HOME'
        or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
    return path.join(config_home, 'snowcone')
end

--- Parse a table assignment of the form: (key '.')* key '=' value
--- Keys and values can be numbers, quoted strings, or unquoted strings.
--- (from ircc/init.lua)
function M.apply_override(tab, src)
    local keys = {}
    local key
    local value
    local want = 'key'
    for token, lexeme in lexer.scan(src) do
        if 'key' == want and ('iden' == token or 'string' == token or 'number' == token) then
            key = lexeme
            want = 'separator'
        elseif 'separator' == want and '.' == token then
            table.insert(keys, key)
            want = 'key'
        elseif 'separator' == want and '=' == token then
            want = 'value'
        elseif 'value' == want and ('iden' == token or 'string' == token or 'number' == token) then
            value = lexeme
            want = 'eol'
        else
            error(
                'syntax error at \x1f' .. lexeme ..
                '\x1f got \x02' .. token ..
                '\x02 expected \x02' .. want ..
                '\x02 in \x1f' .. src, 0)
        end
    end

    for _, x in ipairs(keys) do
        if not tab[x] then
            tab[x] = {}
        end
        tab = tab[x]
    end
    tab[key] = value
end

local function parse(filename, text)
    local ext = path.extension(filename)
    if ext == '.toml' then
        return assert(mytoml.parse_toml(text))
    elseif ext == '.lua' then
        -- assignments in the file stay out of _G
        local env = setmetatable({}, {__index = _G})
        local chunk = assert(load(text, '@' .. filename, 't', env))
        return chunk()
    else
        error('Unknown configuration file extension: ' .. ext, 0)
    end
end

--- Read the configuration file named by --config, or the first default
--- that exists.
---@return table raw configuration
---@return string filename
local function read_file(dir, flags)
    if flags.config then
        local text = file.read(flags.config)
        if not text then
            error('Failed to read configuration file: ' .. flags.config, 0)
        end
        return parse(flags.config, text), flags.config
    end

    local candidates = {
        path.join(dir, 'hub.toml'),
        path.join(dir, 'hub.lua'),
    }
    for _, filename in ipairs(candidates) do
        local text = file.read(filename)
        if text then
            return parse(filename, text), filename
        end
    end
    error('Failed to read configuration file, tried: ' .. table.concat(candidates, ', '), 0)
end

local all_features <const> = {}
for _, name in ipairs(cschema.features) do
    all_features[name] = true
end

local function normalize_network(net, warnings)
    if net.id == nil and type(net.server) == 'table' and type(net.server.host) == 'string' then
        net.id = net.server.host
    end

    schema.check(cschema.network, net, {'networks', tostring(net.id)}, warnings)

    if net.features then
        local set = {}
        for _, name in ipairs(net.features) do
            if not all_features[name] then
                error(string.format('networks.%s.features: unknown feature %s (known: %s)',
                    net.id, name, table.concat(cschema.features, ', ')), 0)
            end
            set[name] = true
        end
        net.features = set
    else
        net.features = tablex.copy(all_features)
    end

    if net.autoconnect == nil then net.autoconnect = true end
    if net.reclaim_nick == nil then net.reclaim_nick = true end
    net.reconnect = net.reconnect or {}
    net.reconnect.min_delay = net.reconnect.min_delay or 1
    net.reconnect.max_delay = net.reconnect.max_delay or 300
    if net.reconnect.max_delay < net.reconnect.min_delay then
        error(string.format('networks.%s.reconnect: max_delay is below min_delay', net.id), 0)
    end
    net.layers = net.layers or {}
    return net
end

--- Validate and normalize a raw configuration table. The table is copied
--- first, so the caller's stays untouched.
---@param raw table
---@return table configuration
function M.normalize(raw)
    raw = tablex.deepcopy(raw)
    local warnings = {}
    schema.check(cschema.file, raw, {}, warnings)

    local networks = {}
    local seen = {}
    for i, net in ipairs(raw.networks or {}) do
        if type(net) ~= 'table' then
            error('networks.' .. i .. ' is not a table', 0)
        end
        normalize_network(net, warnings)
        if seen[net.id] then
            error('Duplicate network id: ' .. net.id, 0)
        end
        seen[net.id] = true
        table.insert(networks, net)
    end

    local ui = raw.ui or {}
    ui.profile = ui.profile or 'all'

    return {
        warnings = warnings,
        ui = ui,
        plugins = raw.plugins,
        notifications = raw.notifications,
        mention = raw.mention,
        networks = networks,
    }
end

--- Load configuration from the command line and files.
---@param args table command line arguments
---@param override table|nil raw configuration to use instead of a file (tests)
---@return table configuration
function M.load(args, override)
    local dir = M.config_dir()
    local raw, filename
    if override then
        raw, filename = override, '(provided)'
    else
        local flags, overrides = app.parse_args(args, {config = true})
        if not flags then
            error('Failed to parse command line flags', 0)
        end
        raw, filename = read_file(dir, flags)
        for _, o in ipairs(overrides) do
            M.apply_override(raw, o)
        end
    end

    local cfg = M.normalize(raw)
    cfg.file = filename
    cfg.dir = dir
    return cfg
end

--- Configuration of one network, from the active configuration.
---@param id string
---@return table|nil
function M.network(id)
    local cfg = HUB.state.config
    if cfg then
        for _, net in ipairs(cfg.networks) do
            if net.id == id then return net end
        end
    end
end

--- Resolve a path from the configuration: absolute paths are kept,
--- relative ones are relative to the configuration directory.
---@param entry string|nil
---@return string|nil
function M.resolve_path(entry)
    if entry == nil then
        return nil
    end
    if path.isabs(entry) then
        return entry
    end
    local cfg = HUB.state and HUB.state.config
    return path.join(cfg and cfg.dir or M.config_dir(), entry)
end

return M
