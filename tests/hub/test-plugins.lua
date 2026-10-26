-- Plugins: the api, failures that stay contained, and reloads.
--
-- Run with:  snowcone tests/hub/test-plugins.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local path = require 'pl.path'
local file = require 'pl.file'

-- A directory of plugin files for these tests
local dir = os.tmpname()
os.remove(dir)
path.mkdir(dir)

local sources = {
    good = [[
return function(api)
    api.state.loads = (api.state.loads or 0) + 1
    api.on('irc.message', function(ev)
        table.insert(HUB.test_seen, ev.msg.command)
    end)
    api.command('greet', '$g', function(ctx, who)
        api.send(ctx.net, 'PRIVMSG', who, 'hello from ' .. api.name)
    end, 'say hello')
    api.view('goodview', {render = function() end})
    HUB.test_timer = api.timer(60000, function() end)
    api.timer(10, function() HUB.test_fired = true end)
end
]],
    broken = [[error 'broken at load']],
    old = [[return {name = 'old', irc = function() end}]],
    older = [[local N = require 'utils.numerics' return {name = 'older'}]],
    clash = [[return function(api) api.command('quit', '', function() end) end]],
    boom = [[
return function(api)
    api.on('irc.message', function() error 'handler fails' end)
end
]],
}
for name, src in pairs(sources) do
    assert(file.write(path.join(dir, name .. '.lua'), src))
end

local order = {'boom', 'good', 'broken', 'old', 'older', 'clash', 'missing'}

local function config()
    return {
        plugins = {directory = dir, modules = order},
        networks = {{id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}},
    }
end

local function boot()
    local fake = FakeTransport.new()
    HUB = nil
    T.boot {transport = fake, config = config()}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c, T.require 'hub.features.plugins'
end

local function errors_by_name(plugins)
    local result = {}
    for _, entry in ipairs(plugins.loaded) do
        result[entry.name] = entry.error and tostring(entry.error):match '^[^\n]*' or false
    end
    return result
end

T.case('plugins load, and failures stay with their plugin', function()
    local _, plugins = boot()
    local errors = errors_by_name(plugins)
    T.eq(errors.good, false, 'good loaded')
    T.eq(errors.boom, false, 'boom loaded')
    T.ok(errors.broken:find('broken at load', 1, true), errors.broken)
    T.ok(errors.old:find('port it to the hub plugin api', 1, true), errors.old)
    T.ok(errors.older:find('it needs utils.numerics); port it', 1, true), errors.older)
    T.ok(errors.missing, 'missing file reported')
    T.ok(HUB.current.commands.greet, 'command registered')
    T.ok(HUB.current.views.goodview, 'view registered')
    local logged = table.concat(T.log_lines 'plugin', '\n')
    T.ok(logged:find('clash command quit', 1, true), 'clashing command reported')
    T.eq(HUB.current.commands.quit.owner, 'hub.commands.core', 'the built-in kept')
end)

T.case('handlers, commands, state and timers', function()
    local c = boot()
    HUB.test_seen = {}
    c:recv ':x!u@h PRIVMSG me :hi'
    T.eq(HUB.test_seen, {'PRIVMSG'}, 'good saw it although boom raised first')
    local errors = T.log_lines 'plugin'
    T.ok(errors[#errors]:find('handler fails', 1, true), 'boom logged')

    T.require 'hub.ui.control'.init_state(HUB.state)
    T.require 'hub.ui.cmdline'.execute 'greet friend'
    T.eq(c:take(), {'PRIVMSG friend :hello from good'}, 'command')

    T.sleep(50)
    T.ok(HUB.test_fired, 'timer fired')
    T.eq(HUB.state.features.plugins.good.loads, 1, 'state')
end)

T.case('a reload reloads plugins, keeps state and closes old timers', function()
    boot()
    local old_timer = HUB.test_timer
    local resources = T.require 'hub.runtime.resources'
    T.ok(resources.get(old_timer), 'timer held')

    T.ok(T.reload {config = config()}, 'reload')
    T.eq(HUB.state.features.plugins.good.loads, 2, 'loaded again with its state')
    T.eq(resources.get(old_timer), nil, "the old generation's timer is closed")
    T.ok(resources.get(HUB.test_timer), "the new generation's timer is held")
end)

-- a case of its own: T.run returns at the first sleep, before later cases
T.case('remove the plugin directory', function()
    for name in pairs(sources) do os.remove(path.join(dir, name .. '.lua')) end
    path.rmdir(dir)
    T.ok(not path.exists(dir), 'removed')
end)

T.run()
