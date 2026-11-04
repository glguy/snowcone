-- Plugins: the api, failures that stay contained, and reloads.
--
-- Run with:  snowcone tests/hub/test-plugins.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
dofile(here .. '/fake_ncurses.lua').install()
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
    api.command('netgreet', '', function(ctx)
        api.net_task(ctx.net, 'greeter', function(t) t:send('PRIVMSG', 'x', 'hi from a net task') end)
    end, 'say hello on a network', nil, {net = true})
    api.view('goodview', {render = function() end})
    HUB.test_timer = api.timer(60000, function() end)
    HUB.test_task = api.task('waiter', function(t) t:sleep(60000) end).id
    api.timer(10, function() HUB.test_fired = true end)
end
]],
    broken = [[error 'broken at load']],
    tabular = [[return {name = 'tabular'}]],
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

local order = {'boom', 'good', 'broken', 'tabular', 'clash', 'missing'}

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
    T.eq(errors.tabular, 'returned table, not a function', 'tabular refused')
    T.ok(errors.missing, 'missing file reported')
    T.ok(HUB.current.commands.greet, 'command registered')
    T.eq({HUB.current.commands.greet.usage, HUB.current.commands.greet.group}, {'word', 'plugin good'},
        'a usage from its spec, and its plugin as group')
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

    T.command 'greet friend'
    T.eq(c:take(), {'PRIVMSG friend :hello from good'}, 'command')
    T.command 'netgreet@test'
    T.eq(c:take(), {'PRIVMSG x :hi from a net task'}, 'a net command and a net task')

    T.sleep(50)
    T.ok(HUB.test_fired, 'timer fired')
    T.eq(HUB.state.features.plugins.good.loads, 1, 'state')
end)

T.case('a reload reloads plugins, keeps state and closes old timers and tasks', function()
    boot()
    local old_timer, old_task = HUB.test_timer, HUB.test_task
    local resources = T.require 'hub.runtime.resources'
    T.ok(resources.get(old_timer), 'timer held')
    T.ok(HUB.tasks[old_task], 'task running')

    T.ok(T.reload {config = config()}, 'reload')
    T.eq(HUB.state.features.plugins.good.loads, 2, 'loaded again with its state')
    T.eq(resources.get(old_timer), nil, "the old generation's timer is closed")
    T.ok(resources.get(HUB.test_timer), "the new generation's timer is held")
    T.eq(HUB.tasks[old_task], nil, "the old generation's task is canceled")
    T.ok(HUB.tasks[HUB.test_task], "the new generation's task runs")
end)

T.case('saved data and httpd replies reach their callers', function()
    assert(file.write(path.join(dir, 'saver.lua'), [[
return function(api)
    local saved = api.load() or {count = 0}
    saved.count = saved.count + 1
    api.save(saved)
    HUB.test_saved = saved.count
    HUB.test_bad_saves = {(pcall(api.save, 5)), (pcall(api.save, {x = 0/0})), (pcall(api.save, {f = print}))}
    HUB.test_path = api.path 'txt'
    api.httpd('::1', 0, function(method, target)
        if target == '/fail' then error 'handler fails' end
        return 200, method .. ' ' .. target, {['Content-Type'] = 'text/plain'}
    end)
end
]]))
    -- capture the callback hub gives the native httpd
    local real = snowcone.start_httpd
    local callback
    snowcone.start_httpd = function(_, _, cb)
        callback = cb
        return {close = function() end}
    end
    local ok, err = pcall(function()
        local function start()
            HUB = nil
            T.boot {strict = false, config = {plugins = {directory = dir, modules = {'saver'}}, networks = {}}}
        end
        start()
        T.eq(HUB.test_saved, 1, 'nothing saved yet')
        T.eq(HUB.test_bad_saves, {false, false, false},
            'only tables of plain values save')
        T.eq(HUB.test_path, path.join(dir, 'saver.txt'), 'path')
        start()
        T.eq(HUB.test_saved, 2, 'loaded what the last start saved')

        T.eq({callback('GET', '/x', '', {})}, {200, 'GET /x', {['Content-Type'] = 'text/plain'}}, 'reply')
        T.eq(select('#', callback('GET', '/fail', '', {})), 0, 'an error gives no reply')
        local logged = T.log_lines 'plugin'
        T.ok(logged[#logged]:find('saver httpd: ', 1, true), 'and is reported as the plugin\'s: ' .. logged[#logged])
    end)
    snowcone.start_httpd = real
    os.remove(path.join(dir, 'saver.dat'))
    os.remove(path.join(dir, 'saver.lua'))
    if not ok then error(err, 0) end
end)

T.case('a log subscriber that raises is reported once per line, not again and again', function()
    assert(file.write(path.join(dir, 'logboom.lua'), [[
return function(api)
    api.on('log', function() error 'log handler fails' end)
end
]]))
    local ok, err = pcall(function()
        HUB = nil
        T.boot {strict = false, config = {plugins = {directory = dir, modules = {'logboom'}}, networks = {}}}
        local before = #T.log_lines 'plugin'
        T.require 'hub.runtime.log'.add('test', 'one line')
        local errors = T.log_lines 'plugin'
        T.eq(#errors - before, 1, 'one error for one line')
        T.ok(errors[#errors]:find('log handler fails', 1, true), errors[#errors])
    end)
    os.remove(path.join(dir, 'logboom.lua'))
    if not ok then error(err, 0) end
end)

T.case('a plugin\'s view, timer and task errors are its own, and a failed view is reported once', function()
    assert(file.write(path.join(dir, 'badview.lua'), [[
return function(api)
    api.view('broken', {render = function() error 'render fails' end})
    api.timer(0, function() error 'timer fails' end)
    api.task('t', function() error 'task fails' end)
end
]]))
    local ok, err = pcall(function()
        HUB = nil
        T.boot {strict = false, ui = true, config = {plugins = {directory = dir, modules = {'badview'}}, networks = {}}}
        T.require 'hub.ui.control'.set_view 'broken'
        for _ = 1, 3 do HUB.current.routes['ui.draw']() end
        HUB.current.routes['plugins.callback'](1)
        local logged = table.concat(T.log_lines 'plugin', '\n')
        local _, renders = logged:gsub('render fails', '')
        T.eq(renders, 1, 'the render failure once: ' .. logged)
        T.ok(logged:find('badview task t: ', 1, true), 'the task under the plugin')
        T.ok(logged:find('badview timer: ', 1, true), 'the timer too')
        T.eq(T.log_lines 'error', {}, 'nothing as a hub error')
    end)
    os.remove(path.join(dir, 'badview.lua'))
    if not ok then error(err, 0) end
end)

-- a case of its own: T.run returns at the first sleep, before later cases
T.case('remove the plugin directory', function()
    for name in pairs(sources) do os.remove(path.join(dir, name .. '.lua')) end
    path.rmdir(dir)
    T.ok(not path.exists(dir), 'removed')
end)

T.run()
