-- Loading and checking configuration (runtime/config.lua).
--
-- Run with:  snowcone tests/hub/test-config.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot = N.network, N.boot

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

local network_toml <const> = [==[
[[networks]]
id = 'test'
server = {host = 'test.example', port = 6667}
identity = {nick = 'me'}
]==]

-- Normalize a configuration and have every module check its part, as a
-- load does
local function check(raw)
    local cfg = T.require 'hub.runtime.config'.normalize(raw)
    for _, entry in ipairs(HUB.current.modules) do
        local m = entry.module
        if type(m) == 'table' and m.check_config then m.check_config(cfg) end
    end
    return cfg
end

T.case('--config names the file; overrides apply on top of it', function()
    local config = config_module()
    local dir = tempdir()
    local file = write(dir .. '/mine.toml', '[ui]\nprofile = "all"\n' .. network_toml)
    local cfg = config.load {'--config=' .. file, 'ui.profile=chat', 'networks.test.identity.nick=you'}
    T.eq({cfg.file, cfg.dir}, {file, dir}, 'the file, and where relative paths start')
    T.eq(cfg.ui.profile, 'chat', 'an override')
    T.eq(cfg.networks[1].identity.nick, 'you', 'an override by network id')
end)

T.case('a configuration file must be readable TOML, named *.toml', function()
    local config = config_module()
    local dir = tempdir()
    T.raises('Configuration files are TOML, named *.toml: ' .. dir .. '/hub.conf', config.load,
        {'--config=' .. write(dir .. '/hub.conf', network_toml)})
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
        local text = network_toml .. 'servers_file = "' .. servers_file .. '"\n'
        return config.load {'--config=' .. write(dir .. '/hub.toml', text)}
    end
    T.raises('networks.test.servers_file: servers files are TOML, named *.toml', load_with, 'servers.txt')
    T.raises('networks.test.servers_file: ', load_with, 'missing.toml')
    write(dir .. '/bad.toml', 'x = = 1')
    T.raises('networks.test.servers_file ' .. dir .. '/bad.toml: ', load_with, 'bad.toml')
    write(dir .. '/servers.toml', '[servers.a]\nregion = "EU"\n')
    T.eq(load_with('servers.toml').networks[1].servers.servers.a.region, 'EU', 'relative to the configuration')
end)

T.case('configuration paths: ~ is home, absolute kept, relative beside the file', function()
    local config = config_module()
    local home = assert(os.getenv 'HOME')
    T.eq(config.resolve_path('~', '/cfg'), home, '~ alone')
    T.eq(config.resolve_path('~/k.pem', '/cfg'), home .. '/k.pem', '~/')
    T.eq(config.resolve_path('~bob/k.pem', '/cfg'), '/cfg/~bob/k.pem', '~user is not expanded')
    T.eq(config.resolve_path('/etc/k.pem', '/cfg'), '/etc/k.pem', 'absolute')
    T.eq(config.resolve_path('a/~/k.pem', '/cfg'), '/cfg/a/~/k.pem', '~ only at the start')
    T.eq(config.user_path('~/k.pem'), home .. '/k.pem', 'typed paths too')
    T.eq(config.user_path('k.pem'), config.config_dir() .. '/k.pem', 'typed paths: the configuration directory')
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

T.case('network defaults', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {{
        id = 'example',
        server = {host = 'irc.example.test', port = 6697},
        identity = {nick = 'n'},
        layers = {{type = 'tls'}},
    }}}}
    local net = HUB.state.config.networks[1]
    T.eq(net.features.snotice and net.features.chat, true, 'all features')
    T.eq({net.autoconnect, net.reclaim_nick}, {true, true}, 'flags')
    T.eq(net.reconnect, {min_delay = 1, max_delay = 300}, 'reconnect')
    T.eq(fake.last().host, 'irc.example.test', 'connects')
    T.eq(fake.last().layers[1].type, 'tls', 'layers')

    local ok, err = pcall(check, {networks = {{
        server = {host = 'irc.example.test', port = 6697},
        identity = {nick = 'n'},
    }}})
    T.eq(ok, false, 'id is required')
    T.ok(err:find('networks.1.id', 1, true), err)
end)

T.case('buffers are checked for repeated names and labels', function()
    T.boot()
    local function load(buffers)
        return pcall(check, {networks = {network('x', {buffers = buffers})}})
    end
    T.ok(load {{name = '#a', label = 'a', activity = false, mention = {patterns = {}}}, {name = '#b', label = false, hidden = true}}, 'accepted')
    local ok, err = load {{name = '#a'}, {name = '#A'}}
    T.ok(not ok and err:find('networks.x.buffers.2: #A is already buffers.1', 1, true), tostring(err))
    ok, err = load {{name = '#a', label = 'q'}, {name = '#b', label = 'q'}}
    T.ok(not ok and err:find('networks.x.buffers.2.label: q is already the label of buffers.1', 1, true), tostring(err))
    ok, err = load {{name = '#a', label = true}}
    T.ok(not ok and err:find('networks.x.buffers.1.label', 1, true), tostring(err))
    ok, err = load {{name = '#a', label = 'ab'}}
    T.ok(not ok and err:find('one letter or digit', 1, true), tostring(err))
    ok, err = load {{name = '#a', level = 'quiet'}}
    T.ok(not ok and err:find('Unexpected field', 1, true), tostring(err))
end)

T.case('hide rules are checked at load', function()
    T.boot()
    local function load(hide)
        local ok, result = pcall(check, {networks = {network('x', {hide = hide})}})
        return ok, ok and result.networks[1].hide or result
    end
    local ok, rules = load {{buffer = '#a', nick = {'b', 'c'}, pattern = '^x'}, {command = 'JOIN', action = 'show'}}
    T.ok(ok, tostring(rules))
    T.eq(rules[1], {buffer = {'#a'}, nick = {'b', 'c'}, pattern = {'^x'}}, 'every field a list')
    T.eq(rules[2].command, {'JOIN'}, 'command')
    local _, none = load(nil)
    T.eq(none, {}, 'none')
    local function fails(hide, needle)
        local done, err = load(hide)
        T.ok(not done and tostring(err):find(needle, 1, true), tostring(err))
    end
    fails({{action = 'hide'}}, 'networks.x.hide.1: matches every message')
    fails({{nick = 'a'}, {nick = 'b', pattern = 'x', regex = 'y'}}, 'networks.x.hide.2: a pattern or a regex, not both')
    fails({{pattern = '[x'}}, 'networks.x.hide.1.pattern.1: ')
    fails({{pattern = 'ok', nick = 'a'}, {pattern = {'fine', 'a%b'}}}, 'networks.x.hide.2.pattern.2: missing arguments to %b')
    fails({{nick = 'a', action = 'drop'}}, 'action must be one of discard, hide, show')
    fails({{command = 'join'}}, 'an IRC command in capitals')
    -- what never matches
    fails({{nick = {}}}, 'networks.x.hide.1.nick: an empty list matches nothing')
    fails({{buffer = '#a', pattern = {}}}, 'networks.x.hide.1.pattern: an empty list matches nothing')
    fails({{command = {'JOIN', 'PING'}}}, 'networks.x.hide.1.command.2: no buffer holds PING')
    fails({{command = '404'}}, 'no buffer holds 404')
    T.ok((load {{command = {'474', 'KICK', 'WALLOPS'}}}), 'channel errors by their digits')
    fails({{nick = {'ok', 'bot!*@*'}}}, 'networks.x.hide.1.nick.2: bot!*@* is matched exactly')
    fails({{account = 'some one'}}, 'networks.x.hide.1.account.1: some one is matched exactly')
    fails({{command = {'JOIN', 'PART'}, pattern = 'x'}}, 'networks.x.hide.1: a pattern or regex matches only PRIVMSG and NOTICE')
    T.ok((load {{command = {'JOIN', 'NOTICE'}, pattern = 'x'}}), 'a pattern with NOTICE among the commands')
    T.ok((load {{nick = 'a', action = 'discard'}}), 'discard')
    fails({{nick = 'a', level = 1}}, 'Unexpected field')
    if pcall(require, 'rex_pcre2') then
        fails({{regex = '('}}, 'networks.x.hide.1.regex.1: ')
    else
        fails({{regex = 'x'}}, 'networks.x.hide.1.regex.1: regular expressions need rex_pcre2')
    end
end)

T.case('mention regexes are checked at load, and need rex_pcre2', function()
    T.boot()
    local regex = T.require 'hub.lib.regex'
    local function load(raw)
        return pcall(check, raw)
    end
    local buffered = {networks = {network('x', {buffers = {{name = '#a', mention = {regexes = {'ok'}}}}})}}
    local ok, err = load(buffered)
    if regex.available then
        T.ok(ok, tostring(err))
        ok, err = load {mention = {regexes = {'fine', '('}}}
        T.ok(not ok and err:find('mention.regexes.2: ', 1, true), tostring(err))
        ok, err = load {networks = {network('x', {mention = {regexes = {'[a'}}})}}
        T.ok(not ok and err:find('networks.x.mention.regexes.1: ', 1, true), tostring(err))
    else
        T.ok(not ok and err:find('networks.x.buffers.1.mention.regexes.1: regular expressions need rex_pcre2', 1, true),
            tostring(err))
    end
    ok, err = load {mention = {patterns = {'^ok', 'me('}}}
    T.ok(not ok and err:find('mention.patterns.2: unfinished capture', 1, true), tostring(err))
    ok, err = load {networks = {network('x', {buffers = {{name = '#a', mention = {patterns = {'a['}}}}})}}
    T.ok(not ok and err:find("networks.x.buffers.1.mention.patterns.1: malformed pattern (missing ']')", 1, true),
        tostring(err))
    ok, err = load {networks = {network('x', {watches = {{pattern = 'fine'}, {pattern = 'x('}}})}}
    T.ok(not ok and err:find('networks.x.watches.2.pattern: ', 1, true), tostring(err))
end)

T.case('an invalid configuration on reload leaves the old one active', function()
    boot {network('test')}
    local before = HUB.state.config
    local ok, err = T.reload {config = {networks = {{id = 'bad'}}}}
    T.eq(ok, false, 'reload fails')
    T.ok(err:find('Missing field', 1, true), err)
    T.ok(HUB.state.config == before, 'old configuration kept')

    ok, err = T.reload {config = {networks = {network('x', {features = {'nope'}})}}}
    T.eq(ok, false, 'unknown feature')
    T.ok(err:find('unknown feature nope', 1, true), err)

    ok, err = T.reload {config = {networks = {network('x', {features = {'oper', 'chat'}})}}}
    T.eq(ok, false, 'a feature without one it requires')
    T.ok(err:find('networks.x.features: oper requires snotice', 1, true), err)
    T.ok(T.reload {config = {networks = {network('x', {features = {'oper', 'snotice'}})}}}, 'with it')

    -- what the modules check themselves (check_config)
    for needle, net in pairs {
        ['networks.x.hide.1: matches every message'] = network('x', {hide = {{action = 'hide'}}}),
        ['networks.x.buffers.2: #A is already'] = network('x', {buffers = {{name = '#a'}, {name = '#A'}}}),
        ['networks.x.mention.patterns.1: '] = network('x', {mention = {patterns = {'('}}}),
        ['networks.x.watches.1.pattern: '] = network('x', {watches = {{pattern = '('}}}),
    } do
        local current = HUB.current
        ok, err = T.reload {config = {networks = {net}}}
        T.eq(ok, false, needle)
        T.ok(err:find(needle, 1, true), err)
        T.ok(HUB.current == current, 'the old generation kept')
    end

    ok, err = T.reload {config = {networks = {network('x', {features = {'topology'}})}}}
    T.eq(ok, false, 'topology, which only snotice shows')
    T.ok(err:find('networks.x.features: topology requires snotice', 1, true), err)
end)

T.case('every feature requirement names known features', function()
    T.boot()
    local cschema = T.require 'hub.runtime.config_schema'
    local known = {}
    for _, name in ipairs(cschema.features) do known[name] = true end
    for name, needs in pairs(cschema.feature_requires) do
        T.ok(known[name], 'known: ' .. name)
        for _, needed in ipairs(needs) do
            T.ok(known[needed] and needed ~= name, name .. ' requires known ' .. needed)
        end
    end
end)

T.case('the schema accepts network settings in every form, and refuses what would break a line', function()
    T.boot()
    T.ok(pcall(check, {networks = {{id = 'x', server = {host = 'h', port = 1}, identity = {nick = 'n'}}}}),
        'baseline accepted')
    T.ok(pcall(check, {networks = {{id = 'x', server = {path = '/p'}, identity = {nick = 'n'}}}}),
        'a local socket accepted')
    T.ok(pcall(check, {networks = {{id = 'x', server = {host = 'h', port = 1}, identity = {nick = 'n'},
        rate_limit = {burst = 5, interval = 0.5}}}}), 'a rate limit accepted')
    local ok, err = pcall(check, {networks = {{id = 'x', server = {host = 'h', port = 1},
        identity = {nick = 'n'}, layers = {{type = 'http', host = 'p', port = 8080, username = 'a:b'}}}}})
    T.ok(not ok and err:find('expected no colon', 1, true), 'the reason is given: ' .. tostring(err))
    for _, good in ipairs {
        {layers = {{type = 'http', host = 'p', port = 8080, username = 'u', password = ''}}},
        {layers = {{type = 'socks', host = 'p', port = 1080, username = 'u', password = 'p'}}},
        {layers = {{type = 'tls', pin = string.rep('0123456789ABCDEF', 4)}}},
        {websocket = {}},
        {websocket = {host = 'irc.example:443', path = '/irc?a=b', origin = 'https://irc.example'}},
        {websocket = {subprotocols = {}}},
        {websocket = {subprotocols = {'text.ircv3.net', 'binary.ircv3.net'}}},
        {registration = {username = 'me/libera', password = 'p', capabilities = {'-batch'}}},
        {identity = {nick = 'n', realname = 'Real Name'}},
        {layers = {{type = 'tls', client_cert = {file = 'c.pem'}, client_key = {store = 'pkcs11:id=%01'}}}},
        {sasl = {credentials = {{mechanism = 'ECDSA-NIST256P-CHALLENGE', username = 'u', key = {store = 'pkcs11:x'}}}}},
        {sasl = {automatic = {'EXTERNAL', 'main'},
            credentials = {{mechanism = 'EXTERNAL'}, {name = 'main', mechanism = 'PLAIN'}}}},
        {oper = {automatic = {'main', 'challenge'}, credentials = {
            {name = 'main', mechanism = 'password', username = 'o', password = {prompt = 'oper'}},
            {mechanism = 'challenge', username = 'o', key = {store = 'pkcs11:x'}, password = 'pw'},
        }}},
    } do
        local net = {id = 'x', server = {host = 'h', port = 1}, identity = {nick = 'n'}}
        for k, v in pairs(good) do net[k] = v end
        T.ok(pcall(check, {networks = {net}}), 'accepted: ' .. require 'pl.pretty'.write(good, ''))
    end
    for _, bad in ipairs {
        {identity = {nick = 'has space'}},
        {identity = {nick = 'n', user = 'a\nb'}},
        {identity = {nick = 'n', realname = 'a\rb'}},
        {registration = {password = 'line\nbreak'}},
        {registration = {username = 'a:b', password = 'x'}},
        {registration = {capabilities = {'a b'}}},
        {oper = {credentials = {{mechanism = 'password', username = 'o p', password = 'x'}}}},
        {oper = {credentials = {{mechanism = 'challenge', username = 'o\r', key = 'k'}}}},
        {oper = {credentials = {{mechanism = 'password', username = 'o', key = 'k'}}}},
        {oper = {credentials = {{mechanism = 'challenge', username = 'o'}}}},
        {oper = {credentials = {{mechanism = 'OPER', username = 'o', password = 'x'}}}},
        {oper = {automatic = true}},
        {challenge = {username = 'o', key = 'k'}},
        {identity = {nick = 'n', gecos = 'g'}},
        {server = {host = 'h', port = 1, fingerprint = 'x'}},
        {layers = {{type = 'tls', use_store = true}}},
        {layers = {{type = 'tls', client_key = {store = ''}}}},
        {registration = {password = {store = 'pkcs11:x'}}},
        {sasl = {credentials = {{mechanism = 'EXTERNAL', use_store = true}}}},
        {sasl = {automatic = {'PLAIN'}, credentials = {{name = 'main', mechanism = 'PLAIN'}}}},
        {oper = {automatic = {'missing'}, credentials = {{mechanism = 'password', username = 'o', password = 'x'}}}},
        {server = {}},
        {server = {host = 'h'}},
        {server = {host = 'h', port = 0}},
        {server = {path = '/p', host = 'h'}},
        {server = {path = '/p', port = 1}},
        {layers = {{type = 'socks', host = '', port = 1080}}},
        {layers = {{type = 'socks', host = 'p', port = 1080, username = '', password = 'x'}}},
        {layers = {{type = 'socks', host = 'p', port = 1080, username = 'u', password = ''}}},
        {layers = {{type = 'http', host = 'p', port = 8080, username = 'a:b', password = 'x'}}},
        {layers = {{type = 'tls', pin = string.rep('a', 63)}}},
        {layers = {{type = 'tls', pin = 'tls=' .. string.rep('a', 64)}}},
        {layers = {{type = 'websocket'}}},
        {websocket = {path = 'irc'}},
        {websocket = {path = '/a b'}},
        {websocket = {host = 'h\r\nX: y'}},
        {websocket = {host = ''}},
        {websocket = {origin = 'a b'}},
        {websocket = {subprotocols = {'irc'}}},
        {websocket = {subprotocols = 'text.ircv3.net'}},
        {rate_limit = {burst = 5}},
        {rate_limit = {interval = 2}},
        {rate_limit = {burst = 0, interval = 2}},
        {rate_limit = {burst = 1.5, interval = 2}},
        {rate_limit = {burst = 5, interval = 0}},
        {reconnect = {min_delay = 0, max_delay = 1}},
        {rate_limit = {burst = 5, interval = 0/0}},
        {reconnect = {min_delay = 1, max_delay = math.huge}},
        {watches = {{pattern = 'x', color = 'duration'}}},
        {watches = {{pattern = 'x', color = 'orange'}}},
        {identity = {nick = 'n', user = ':x'}},
        {snomask = ':+s'},
        {oper = {credentials = {{mechanism = 'password', username = ':o', password = 'x'}}}},
    } do
        local net = {id = 'x', server = {host = 'h', port = 1}, identity = {nick = 'n'}}
        for k, v in pairs(bad) do net[k] = v end
        T.ok(not pcall(check, {networks = {net}}), 'rejected: ' .. require 'pl.pretty'.write(bad, ''))
    end
end)

T.case('overrides reach any setting, with TOML values', function()
    T.boot {}
    local config = T.require 'hub.runtime.config'
    local raw = {networks = {{id = 'libera'}, {id = 'oftc'}}}
    config.apply_override(raw, 'networks.oftc.reclaim_nick=false')
    config.apply_override(raw, 'networks.1.features=["chat"]')
    config.apply_override(raw, 'ui.profile=chat')
    config.apply_override(raw, "mention.patterns=['a=b']")
    T.eq(raw, {
        networks = {{id = 'libera', features = {'chat'}}, {id = 'oftc', reclaim_nick = false}},
        ui = {profile = 'chat'},
        mention = {patterns = {'a=b'}},
    }, 'applied')
    for _, bad in ipairs {'ui.profile', 'networks.nope.x=1', 'ui..x=1', 'ui.profile.x=1'} do
        local ok, err = pcall(config.apply_override, raw, bad)
        T.ok(not ok and not tostring(err):find 'traceback', bad .. ': ' .. tostring(err))
    end
end)

-- The error for TOML that must not parse
local function toml_error(text, what)
    local value, err = mytoml.parse_toml(text)
    T.eq(value, nil, what)
    return assert(err, what)
end

T.case('TOML errors give positions, not the text of the file', function()
    local err = toml_error('a = 1\npassword = "hunter2\n', 'rejected')
    T.ok(err:find('line 2, column', 1, true), err)
    T.ok(not err:find('hunter2', 1, true), err)
    T.ok(not err:find('parse_toml', 1, true), err)
    T.ok(not err:find('toml::', 1, true), err)

    -- a type TOML has and Lua doesn't
    err = toml_error('a = 1\nb = 1979-05-27\n', 'date rejected')
    T.ok(err:find('line 2, column 5: local_date', 1, true), err)

    -- many mistakes make a bounded message
    err = toml_error(string.rep('x\n', 100), 'all rejected')
    T.ok(err:find('and %d+ more$'), err)
    T.eq(select(2, err:gsub('\n', '')), 5, 'five errors and the count')

    -- each error is one line, though this one's note holds a line break
    err = toml_error('[a] b = 1\n', 'text after a table rejected')
    T.ok(not err:find '%c', err)

    -- one mistake reported at two levels of nesting reads once
    err = toml_error('a = [\n[1 [ # c\n]]\n]\n', 'nesting rejected')
    local first, second = err:match '^([^\n]*)\n([^\n]*)'
    T.ok(first and first ~= second, err)
end)

T.case('TOML binary integers use the whole range', function()
    local function v(text) return (mytoml.parse_toml('v = ' .. text) or {}).v end
    T.eq(v('0b' .. string.rep('1', 63)), math.maxinteger, 'the largest')
    T.eq(v('0b' .. string.rep('0', 100) .. '101'), 5, 'leading zeros do not count')
    T.eq(v('0b0000_0000'), 0, 'zero')
    T.eq(v('0b1' .. string.rep('0', 63)), nil, 'one past the largest')
    T.eq(v('0b' .. string.rep('1', 64)), nil, 'too many digits')
end)

T.case('TOML floats out of range', function()
    local function v(text) return (mytoml.parse_toml('v = ' .. text) or {}).v end
    T.eq(v('1e-310'), 1e-310, 'subnormal')
    T.eq(v('5e-324'), 5e-324, 'the smallest subnormal')
    T.eq(v('-1e-310'), -1e-310, 'negative subnormal')
    T.eq(v('1e-999'), 0.0, 'too small rounds to zero')
    T.eq(v('1.7976931348623157e308'), 1.7976931348623157e308, 'the largest')
    T.eq(v('-1.7976931348623157e308'), -1.7976931348623157e308, 'the lowest')
    T.eq(v('1e999'), nil, 'too large')
    T.eq(v('-1e999'), nil, 'too large and negative')
    T.eq(v('1.8e308'), nil, 'just too large')

    local err = toml_error('v = 1e999', 'too large')
    T.ok(err:find('too large', 1, true), err)
end)

T.run()
