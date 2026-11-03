-- Reading and validating configuration.
--
-- The result is plain data:
--   {file, dir, ui, plugins, notifications, mention,
--    networks = {{id, features = {[name] = true}, ...}, ...}}
-- Secrets stay as configured (strings, {command=}, {file=}, {prompt=});
-- they are resolved at connect time by runtime/secrets.lua. A network's
-- servers file is read here into `servers`; one that can't be read fails
-- the load like the configuration file itself.

local app     <const> = require 'pl.app'
local file    <const> = require 'pl.file'
local path    <const> = require 'pl.path'
local tablex  <const> = require 'pl.tablex'
local casemap <const> = require 'hub.lib.casemap'
local schema  <const> = require 'hub.lib.schema'
local cschema <const> = require 'hub.runtime.config_schema'

local M = {}

--- Directory holding configuration, plugins and saved data.
function M.config_dir()
    local config_home = os.getenv 'XDG_CONFIG_HOME'
        or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
    return path.join(config_home, 'snowcone')
end

--- Apply a command-line override, KEY.PATH=value, to raw configuration.
--- The path is split at dots; a number indexes a list, and a name under
--- `networks` is a network's id. The value is read as a TOML value (true,
--- 3, 'text', [1, 2]), or else taken as text.
function M.apply_override(tab, src)
    local keypath, value = src:match '^([^=]+)=(.*)$'
    if keypath == nil then
        error('override needs KEY.PATH=value: ' .. src, 0)
    end

    local keys = {}
    for key in (keypath .. '.'):gmatch '([^.]*)%.' do
        if key == '' then
            error('override has an empty key: ' .. src, 0)
        end
        table.insert(keys, math.tointeger(tonumber(key)) or key)
    end

    local parsed = mytoml.parse_toml('v = ' .. value)
    if parsed then
        value = parsed.v
    end

    for i = 1, #keys - 1 do
        local key = keys[i]
        if keys[i - 1] == 'networks' and i == 2 and type(key) == 'string' then
            -- a network by its id
            local found
            for j, net in ipairs(tab) do
                if type(net) == 'table' and net.id == key then found = j end
            end
            if not found then
                error('override names no network ' .. key .. ': ' .. src, 0)
            end
            key = found
        end
        if tab[key] == nil then
            tab[key] = {}
        elseif type(tab[key]) ~= 'table' then
            error('override goes inside a value that is not a table: ' .. src, 0)
        end
        tab = tab[key]
    end
    tab[keys[#keys]] = value
end

local function parse(filename, text)
    if path.extension(filename) ~= '.toml' then
        error('Configuration files are TOML, named *.toml: ' .. filename, 0)
    end
    local raw, err = mytoml.parse_toml(text)
    if raw == nil then
        error(filename .. ': ' .. tostring(err), 0)
    end
    return raw
end

--- Read the configuration file chosen by /reload, else the one named by
--- --config, else hub.toml in the configuration directory.
---@param chosen string|nil
---@return table raw
---@return string filename
local function read_file(dir, flags, chosen)
    local named = chosen or flags.config
    if named then
        local text = file.read(named)
        if not text then
            error('Failed to read configuration file: ' .. named, 0)
        end
        return parse(named, text), named
    end

    local filename = path.join(dir, 'hub.toml')
    local text = file.read(filename)
    if not text then
        error('Failed to read configuration file: ' .. filename, 0)
    end
    return parse(filename, text), filename
end

--- The first `sasl` or `oper` credential with a given name; a
--- credential's name defaults to its mechanism.
---@param credentials table[]|nil
---@param name string
---@return table|nil
function M.get_credential(credentials, name)
    for _, credential in ipairs(credentials or {}) do
        if (credential.name or credential.mechanism) == name then
            return credential
        end
    end
end

--- The credentials a `sasl` or `oper` table's `automatic` names, in
--- order. The load checks that each name is found.
---@param cfg table|nil the `sasl` or `oper` table
---@return table[]
function M.automatic_credentials(cfg)
    local credentials = {}
    for _, name in ipairs(cfg and cfg.automatic or {}) do
        table.insert(credentials, M.get_credential(cfg.credentials, name))
    end
    return credentials
end

--- The `sasl` or `oper` credentials a command uses: the one named, or
--- without a name the `automatic` ones, or else the first. Raises when
--- there is none, or none by that name.
---@param cfg table|nil the `sasl` or `oper` table
---@param name string the command's argument, '' for none
---@return table[]
function M.pick_credentials(cfg, name)
    local credentials = cfg and cfg.credentials or {}
    if name ~= '' then
        local credential = M.get_credential(credentials, name)
        if not credential then
            error('unknown credential: ' .. name, 0)
        end
        return {credential}
    end
    local picked = M.automatic_credentials(cfg)
    if not picked[1] then
        picked[1] = credentials[1]
    end
    if not picked[1] then
        error('no credentials', 0)
    end
    return picked
end

local all_features <const> = {}
for _, name in ipairs(cschema.features) do
    all_features[name] = true
end

-- `i` names the network in errors until its id is known to be valid
local function normalize_network(net, i)
    local label = type(net.id) == 'string' and net.id or tostring(i)
    schema.check(cschema.network, net, {'networks', label})

    local server = net.server
    if server.path then
        if server.host or server.port then
            error(string.format('networks.%s.server: path is a local socket; leave out host and port', net.id), 0)
        end
    elseif not server.host then
        error(string.format('networks.%s.server: host and port, or path, is required', net.id), 0)
    elseif not server.port then
        error(string.format('networks.%s.server: port is required with host', net.id), 0)
    end

    for _, section in ipairs {'sasl', 'oper'} do
        local cfg = net[section]
        for _, name in ipairs(cfg and cfg.automatic or {}) do
            if not M.get_credential(cfg.credentials, name) then
                error(string.format('networks.%s.%s.automatic: no credential named %s', net.id, section, name), 0)
            end
        end
    end

    if net.ircd == nil then
        net.ircd = 'solanum'
    elseif not tablex.find(cschema.ircds, net.ircd) then
        error(string.format('networks.%s.ircd: unknown ircd %s (known: %s)',
            net.id, net.ircd, table.concat(cschema.ircds, ', ')), 0)
    end

    if net.features then
        local set = {}
        for _, name in ipairs(net.features) do
            if not all_features[name] then
                error(string.format('networks.%s.features: unknown feature %s (known: %s)',
                    net.id, name, table.concat(cschema.features, ', ')), 0)
            end
            set[name] = true
        end
        for name in pairs(set) do
            for _, needed in ipairs(cschema.feature_requires[name] or {}) do
                if not set[needed] then
                    error(string.format('networks.%s.features: %s requires %s', net.id, name, needed), 0)
                end
            end
        end
        net.features = set
    else
        net.features = tablex.copy(all_features)
    end

    -- names alike in ASCII case are alike in every casemapping
    local names, labels = {}, {}
    for n, buffer in ipairs(net.buffers or {}) do
        local key = casemap.fold('ascii', buffer.name)
        if names[key] then
            error(string.format('networks.%s.buffers.%d: %s is already buffers.%d',
                net.id, n, buffer.name, names[key]), 0)
        end
        names[key] = n
        local key_label = buffer.label
        if key_label == true then
            error(string.format('networks.%s.buffers.%d.label: a letter or digit, or false for none', net.id, n), 0)
        elseif key_label then
            if labels[key_label] then
                error(string.format('networks.%s.buffers.%d.label: %s is already the label of buffers.%d',
                    net.id, n, key_label, labels[key_label]), 0)
            end
            labels[key_label] = n
        end
    end
    net.buffers = net.buffers or {}

    if net.autoconnect == nil then net.autoconnect = true end
    if net.reclaim_nick == nil then net.reclaim_nick = true end
    net.reconnect = net.reconnect or {}
    net.reconnect.min_delay = net.reconnect.min_delay or 1
    net.reconnect.max_delay = net.reconnect.max_delay or 300
    if net.reconnect.max_delay < net.reconnect.min_delay then
        error(string.format('networks.%s.reconnect: max_delay is below min_delay', net.id), 0)
    end
    if net.rate_limit and net.rate_limit.interval <= 0 then
        error(string.format('networks.%s.rate_limit: interval must be above 0', net.id), 0)
    end
    net.layers = net.layers or {}
    net.registration = net.registration or {}
    -- the servers file's contents, or these defaults without one
    net.servers = {servers = {}, regions = {}, kline_reasons = {}, kline_tags = {}}
    return net
end

-- The servers file, a TOML file checked against cschema.servers_file:
-- {servers = {[name] = {alias, region, ipv4, ipv6, expect}},
-- regions = {[label] = {hostname, color}}, kline_reasons = {{name, reason}},
-- kline_tags, net_tracks, flags, primary_hub}
local function read_servers(net, dir)
    local name = net.servers_file
    if not name then return end
    local filename = path.isabs(name) and name or path.join(dir, name)
    if path.extension(filename) ~= '.toml' then
        error(string.format('networks.%s.servers_file: servers files are TOML, named *.toml: %s',
            net.id, filename), 0)
    end
    local text, err = file.read(filename)
    if not text then
        error(string.format('networks.%s.servers_file: %s', net.id, err or filename), 0)
    end
    local value, perr = mytoml.parse_toml(text)
    if not value then
        error(string.format('networks.%s.servers_file %s: %s', net.id, filename, perr), 0)
    end
    schema.check(cschema.servers_file, value, {'networks', net.id, 'servers_file'})
    for k, v in pairs(value) do
        net.servers[k] = v
    end
end

--- Validate and normalize a raw configuration table. The table is copied
--- first, so the caller's stays untouched.
---@param raw table
---@return table
function M.normalize(raw)
    raw = tablex.deepcopy(raw)
    schema.check(cschema.file, raw, {})

    local networks = {}
    local seen = {}
    for i, net in ipairs(raw.networks or {}) do
        if type(net) ~= 'table' then
            error('networks.' .. i .. ' is not a table', 0)
        end
        normalize_network(net, i)
        if seen[net.id] then
            error('Duplicate network id: ' .. net.id, 0)
        end
        seen[net.id] = true
        table.insert(networks, net)
    end

    local ui = raw.ui or {}
    ui.profile = ui.profile or 'all'

    return {
        ui = ui,
        plugins = raw.plugins,
        notifications = raw.notifications,
        mention = raw.mention,
        networks = networks,
    }
end

--- Load configuration from the command line and files.
---@param args string[] command line: --config and key=value overrides
---@param override table|nil raw configuration to use instead of a file
---@param chosen string|nil a file to read in place of --config
---@return table
function M.load(args, override, chosen)
    local dir = M.config_dir()
    local raw, filename
    if override then
        raw, filename = override, '(provided)'
    else
        local flags, overrides = app.parse_args(args, {config = true})
        if not flags then
            error('Failed to parse command line flags', 0)
        end
        raw, filename = read_file(dir, flags, chosen)
        -- relative paths in a file are relative to where it is
        dir = path.dirname(path.abspath(filename))
        for _, o in ipairs(overrides) do
            M.apply_override(raw, o)
        end
    end

    local cfg = M.normalize(raw)
    cfg.file = filename
    cfg.dir = dir
    for _, net in ipairs(cfg.networks) do
        read_servers(net, dir)
    end
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

--- A path typed in a command: ~ expanded, and relative to the
--- configuration directory.
---@param text string
---@return string
function M.user_path(text)
    return path.join(M.config_dir(), path.expanduser(text))
end

--- Resolve a path from the configuration: absolute paths are kept,
--- relative ones are relative to the configuration file's directory (the
--- configuration directory for a configuration not read from a file).
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
