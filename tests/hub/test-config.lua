-- Loading and checking configuration (runtime/config.lua).
--
-- Run with:  snowcone tests/hub/test-config.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

-- A fresh directory, removed when the case ends
local function tempdir()
    local dir = os.tmpname()
    os.remove(dir)
    assert(require 'pl.path'.mkdir(dir))
    T.cleanup(function() require 'pl.dir'.rmtree(dir) end)
    return dir
end

local function write(filename, text)
    local f = assert(io.open(filename, 'w'))
    f:write(text)
    f:close()
    return filename
end

local function config_module()
    T.boot()
    return T.require 'hub.runtime.config'
end

local network <const> = [==[
[[networks]]
id = 'test'
server = {host = 'test.example', port = 6667}
identity = {nick = 'me'}
]==]

T.case('--config names the file; overrides apply on top of it', function()
    local config = config_module()
    local dir = tempdir()
    local file = write(dir .. '/mine.toml', '[ui]\nprofile = "all"\n' .. network)
    local cfg = config.load {'--config=' .. file, 'ui.profile=chat', 'networks.test.identity.nick=you'}
    T.eq({cfg.file, cfg.dir}, {file, dir}, 'the file, and where relative paths start')
    T.eq(cfg.ui.profile, 'chat', 'an override')
    T.eq(cfg.networks[1].identity.nick, 'you', 'an override by network id')
end)

T.case('a configuration file must be readable TOML, named *.toml', function()
    local config = config_module()
    local dir = tempdir()
    T.raises('Configuration files are TOML, named *.toml: ' .. dir .. '/hub.conf', config.load,
        {'--config=' .. write(dir .. '/hub.conf', network)})
    T.raises('Failed to read configuration file: ' .. dir .. '/missing.toml', config.load,
        {'--config=' .. dir .. '/missing.toml'})
    T.raises(dir .. '/bad.toml: ', config.load, {'--config=' .. write(dir .. '/bad.toml', 'x = = 1')})
end)

T.case('networks are checked as a whole: ids, reconnect delays, rate limits', function()
    local config = config_module()
    local function net(extra)
        local n = {id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}
        for k, v in pairs(extra or {}) do n[k] = v end
        return n
    end
    T.raises('Duplicate network id: test', config.normalize, {networks = {net(), net()}})
    T.raises('networks.test.reconnect: max_delay is below min_delay', config.normalize,
        {networks = {net {reconnect = {min_delay = 10, max_delay = 5}}}})
    local cfg = config.normalize {networks = {net()}}
    T.eq(cfg.networks[1].reconnect, {min_delay = 1, max_delay = 300}, 'default delays')
    T.eq({cfg.networks[1].autoconnect, cfg.networks[1].reclaim_nick}, {true, true}, 'default flags')
end)

T.case('a servers file must be readable TOML that fits its schema', function()
    local config = config_module()
    local dir = tempdir()
    local function load_with(servers_file)
        local text = network .. 'servers_file = "' .. servers_file .. '"\n'
        return config.load {'--config=' .. write(dir .. '/hub.toml', text)}
    end
    T.raises('networks.test.servers_file: servers files are TOML, named *.toml', load_with, 'servers.txt')
    T.raises('networks.test.servers_file: ', load_with, 'missing.toml')
    write(dir .. '/bad.toml', 'x = = 1')
    T.raises('networks.test.servers_file ' .. dir .. '/bad.toml: ', load_with, 'bad.toml')
    write(dir .. '/servers.toml', '[servers.a]\nregion = "EU"\n')
    T.eq(load_with('servers.toml').networks[1].servers.servers.a.region, 'EU', 'relative to the configuration')
end)

T.case('a command picks the credential it names, the automatic ones, or the first', function()
    local config = config_module()
    local creds = {automatic = {'b'}, credentials = {{name = 'a'}, {name = 'b'}, {mechanism = 'c'}}}
    T.eq(config.pick_credentials(creds, 'c'), {{mechanism = 'c'}}, 'by name, a mechanism by default')
    T.eq(config.pick_credentials(creds, ''), {{name = 'b'}}, 'the automatic ones')
    T.eq(config.pick_credentials({credentials = creds.credentials}, ''), {{name = 'a'}}, 'else the first')
    T.raises('unknown credential: d', config.pick_credentials, creds, 'd')
    T.raises('no credentials', config.pick_credentials, nil, '')
end)

T.run()
