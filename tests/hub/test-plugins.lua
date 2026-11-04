-- Plugins: the api, failures that stay contained, and reloads.
--
-- Run with:  snowcone tests/hub/test-plugins.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
dofile(here .. '/fake_ncurses.lua').install()
local path = require 'pl.path'
local file = require 'pl.file'

-- What the plugins below leave on HUB for these tests to read
---@class hub.Root
---@field test_seen string[]
---@field test_timer integer
---@field test_task integer
---@field test_fired boolean|string[]
---@field test_saved integer
---@field test_bad_saves boolean[]
---@field test_path string
---@field test_canceled integer
---@field test_cancel fun(id: integer)
---@field test_open fun(kind: string, net: string|nil, data: any)
---@field test_drawn string|nil
---@field test_calls integer

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
    local logged = table.concat(T.log_lines 'error', '\n')
    T.ok(logged:find('clash command quit', 1, true), 'clashing command reported')
    T.eq(HUB.current.commands.quit.owner, 'hub.commands.core', 'the built-in kept')
end)

T.case('handlers, commands, state and timers', function()
    local c = boot()
    HUB.test_seen = {}
    c:recv ':x!u@h PRIVMSG me :hi'
    T.eq(HUB.test_seen, {'PRIVMSG'}, 'good saw it although boom raised first')
    local errors = T.log_lines 'error'
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
    ---@diagnostic disable-next-line: duplicate-set-field
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
        local logged = T.log_lines 'error'
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
        local before = #T.log_lines 'error'
        T.require 'hub.runtime.log'.add('test', 'one line')
        local errors = T.log_lines 'error'
        T.eq(#errors - before, 1, 'one error for one line')
        T.ok(errors[#errors]:find('log handler fails', 1, true), errors[#errors])
    end)
    os.remove(path.join(dir, 'logboom.lua'))
    if not ok then error(err, 0) end
end)

T.case('a plugin\'s view, timer and task errors carry its name, and a failed view is reported once', function()
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
        local logged = table.concat(T.log_lines 'error', '\n')
        local _, renders = logged:gsub('render fails', '')
        T.eq(renders, 1, 'the render failure once: ' .. logged)
        T.ok(logged:find('badview task t: ', 1, true), 'the task under the plugin')
        T.ok(logged:find('badview timer: ', 1, true), 'the timer too')
    end)
    os.remove(path.join(dir, 'badview.lua'))
    if not ok then error(err, 0) end
end)

T.case('a timer\'s callback goes when it fires or is canceled', function()
    assert(file.write(path.join(dir, 'timers.lua'), [[
return function(api)
    local fired = {}
    HUB.test_fired = fired
    api.timer(0, function() table.insert(fired, 'fires') end)
    HUB.test_canceled = api.timer(60000, function() table.insert(fired, 'canceled') end)
    api.cancel_timer(HUB.test_canceled)
    -- a timer that starts the next, as a repeating one does
    local function again(n)
        table.insert(fired, 'again ' .. n)
        if n < 2 then api.timer(0, function() again(n + 1) end) end
    end
    api.timer(0, function() again(1) end)
    HUB.test_cancel = api.cancel_timer
end
]]))
    local ok, err = pcall(function()
        T.boot {config = {plugins = {directory = dir, modules = {'timers'}}, networks = {}}}
        local resources = T.require 'hub.runtime.resources'
        T.eq(resources.get(HUB.test_canceled), nil, 'a canceled timer is closed')
        T.sleep(50)
        T.eq(HUB.test_fired, {'fires', 'again 1', 'again 2'}, 'each fired once, and none was canceled')

        -- callbacks 1 to 4 are the timers above: they are gone, so a late
        -- firing of any of them runs nothing
        for id = 1, 4 do HUB.current.routes['plugins.callback'](id) end
        T.eq(#HUB.test_fired, 3, 'no callback is left to run')
        HUB.test_cancel(HUB.test_canceled)
        T.eq(T.log_lines 'error', {}, 'canceling one that is done does nothing')
    end)
    os.remove(path.join(dir, 'timers.lua'))
    if not ok then error(err, 0) end
end)

T.case('api.show_view shows a view, and refuses one that does not exist', function()
    assert(file.write(path.join(dir, 'shower.lua'), [[
return function(api)
    api.view('shown', {render = function() end})
    api.command('showit', '$g', function(_, id) api.show_view(id) end)
end
]]))
    local ok, err = pcall(function()
        T.boot {strict = false, ui = true, config = {plugins = {directory = dir, modules = {'shower'}}, networks = {}}}
        T.command 'showit shown'
        T.eq(HUB.state.ui.view, 'shown', "the plugin's view")
        T.command 'showit status'
        T.eq(HUB.state.ui.view, 'status', 'a built-in view')
        T.command 'showit nothing'
        T.eq(HUB.state.ui.view, 'status', 'an unknown view changes nothing')
        local logged = T.log_lines 'error'
        T.ok(logged[#logged]:find('no such view: nothing', 1, true), logged[#logged])

        -- without a UI there is nothing to show
        T.boot {config = {plugins = {directory = dir, modules = {'shower'}}, networks = {}}}
        T.command 'showit shown'
        T.eq(T.log_lines 'error', {}, 'headless, it does nothing')
    end)
    os.remove(path.join(dir, 'shower.lua'))
    if not ok then error(err, 0) end
end)

T.case('api.open_detail opens each documented kind, and a kind that cannot draw closes', function()
    assert(file.write(path.join(dir, 'opener.lua'), [[
return function(api) HUB.test_open = api.open_detail end
]]))
    local plugins = {directory = dir, modules = {'opener'}}
    local ok, err = pcall(function()
        T.boot {strict = false, ui = true, transport = FakeTransport.new(), config = {
            plugins = plugins,
            networks = {{id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}},
        }}
        local open, control = HUB.test_open, T.require 'hub.ui.control'
        local draw = HUB.current.routes['ui.draw']

        for _, case in ipairs {
            {'value', nil, {code = 'seen', n = 2, {a = 1}, 'text'}},
            {'value', nil, {n = 0}},
            {'message', 'test', snowcone.parse_irc ':a!b@c PRIVMSG #x :hi'},
            {'channel', 'test', {name = '#x'}},
            {'error', nil, {where = 'somewhere', message = 'it failed'}},
            {'error', nil, {where = 'somewhere', message = 'it failed', traceback = 'stack traceback:\n\tframe'}},
        } do
            open(case[1], case[2], case[3])
            draw()
            T.eq(control.detail() and control.detail().kind, case[1], 'open and drawn: ' .. case[1])
            T.eq(T.log_lines 'error', {}, 'no errors from ' .. case[1])
        end

        control.close_detail()
        local refused, message = pcall(open, 'nonesuch', nil, {})
        T.eq({refused, message}, {false, 'no such detail kind: nonesuch'}, 'an unknown kind')
        T.eq(control.detail(), nil, 'and nothing opened')

        open('error', nil, 42)
        for _ = 1, 3 do draw() end
        local logged = T.log_lines 'error'
        T.eq(#logged, 1, 'data it cannot draw is reported once: ' .. table.concat(logged, ' | '))
        T.ok(logged[1]:find('detail error: ', 1, true), logged[1])
        T.eq(control.detail().kind, 'error', 'and the pane stays, saying so')

        -- without a UI there is nothing to show
        T.boot {config = {plugins = plugins, networks = {}}}
        HUB.test_open('nonesuch', nil, {})
        T.eq(T.log_lines 'error', {}, 'headless, it does nothing')
    end)
    os.remove(path.join(dir, 'opener.lua'))
    if not ok then error(err, 0) end
end)

T.case('api.detail adds a kind for a generation, and its failures are the plugin\'s', function()
    assert(file.write(path.join(dir, 'kinds.lua'), [[
return function(api)
    api.detail('card', {
        title = function(detail) return 'card ' .. detail.data.name end,
        modes = function() return {'mode'} end,
        render = function(ctx, win)
            if ctx.vs.data.bad then error 'card fails' end
            HUB.test_drawn = ctx.vs.data.name
            win:waddstr(ctx.vs.data.name .. '\n')
        end,
        keypress = function(ctx, key)
            if key == string.byte 'x' then ctx.vs.data.pressed = true return true end
        end,
    })
    api.detail('wider', {wide = true, render = function(_, win) win:waddstr(string.rep('x', 300)) end})
    api.detail('value', {render = function() end})
    api.detail('broken_title', {
        title = function() error 'title fails' end,
        render = function(_, win) win:waddstr 'content\n' end,
    })
    api.detail('broken_key', {
        render = function() end,
        keypress = function() error 'key fails' end,
    })
    HUB.test_open = api.open_detail
end
]]))
    local function with_modules(modules)
        return {plugins = {directory = dir, modules = modules}, networks = {}}
    end
    local ok, err = pcall(function()
        T.boot {strict = false, ui = true, config = with_modules {'kinds'}}
        local control = T.require 'hub.ui.control'
        local function draw() HUB.current.routes['ui.draw']() end
        local function plugin_log() return table.concat(T.log_lines 'error', '\n') end

        T.ok(plugin_log():find('plugin kinds detail value: ', 1, true), 'a name taken is reported: ' .. plugin_log())
        T.ok(T.require 'hub.ui.details'.kinds.value.wide, 'and the built-in stays')

        HUB.test_open('card', 'somenet', {name = 'first'})
        draw()
        T.eq(HUB.test_drawn, 'first', 'drawn')
        T.eq(control.detail().net, 'somenet', 'with its network')
        HUB.current.routes['ui.entry']('on_keyboard', string.byte 'x')
        T.ok(control.detail().data.pressed, 'took a key')

        HUB.test_open('wider', nil, {})
        draw()
        T.eq(control.detail().kind, 'wider', 'a wide kind')

        -- a reload adds it again, without clashing with the last generation's
        HUB.test_open('card', nil, {name = 'kept'})
        local before = #T.log_lines 'error'
        T.ok(T.reload {config = with_modules {'kinds'}}, 'reload')
        draw()
        T.eq(control.detail().data.name, 'kept', 'an open pane stays open')
        local after = T.log_lines 'error'
        -- the same one clash, reported again by the new generation, and no other
        T.eq(#after, before + 1, 'only the deliberate clash: ' .. plugin_log())

        -- a failure disables the kind until a reload, once, by name
        HUB.test_drawn = nil
        HUB.test_open('card', nil, {name = 'x', bad = true})
        for _ = 1, 3 do draw() end
        local _, reports = plugin_log():gsub('plugin kinds detail card: [^\n]*card fails', '')
        T.eq(reports, 1, 'reported once, by name: ' .. plugin_log())
        T.eq(control.detail().kind, 'card', 'the pane stays, saying so')
        HUB.test_open('card', nil, {name = 'good'})
        draw()
        T.eq(HUB.test_drawn, nil, 'disabled, even with good data')
        T.ok(T.reload {config = with_modules {'kinds'}}, 'a reload')
        draw()
        T.eq(HUB.test_drawn, 'good', 'brings it back')

        HUB.test_open('broken_title', nil, {})
        for _ = 1, 3 do draw() end
        _, reports = plugin_log():gsub('plugin kinds detail broken_title: [^\n]*title fails', '')
        T.eq(reports, 1, 'a failed title disables it too: ' .. plugin_log())

        -- a key's failure is reported, and the kind stays
        HUB.test_open('broken_key', nil, {})
        HUB.current.routes['ui.entry']('on_keyboard', string.byte 'x')
        T.ok(plugin_log():find('plugin kinds detail broken_key: ', 1, true), plugin_log())
        T.eq(T.require 'hub.ui.details'.kinds.broken_key.origin, 'plugin kinds detail broken_key', 'not disabled')

        -- a plugin no longer loaded takes its kind with it
        T.ok(T.reload {config = with_modules {}}, 'reload without it')
        draw()
        T.eq(control.detail(), nil, 'its pane closes')

        -- without a UI there is nothing to add to
        T.boot {config = with_modules {'kinds'}}
        T.eq(T.log_lines 'error', {}, 'headless, it does nothing')
    end)
    os.remove(path.join(dir, 'kinds.lua'))
    if not ok then error(err, 0) end
end)

local function break_help()
    HUB.current.views.help.render = function() error 'help fails' end
end

T.case('a view that fails to draw is disabled until a reload, built-in or not', function()
    assert(file.write(path.join(dir, 'badviews.lua'), [[
return function(api)
    for _, field in ipairs {'render', 'status', 'modes'} do
        local record = {render = function() end}
        record[field] = function() HUB.test_calls = HUB.test_calls + 1; error(field .. ' fails') end
        api.view('bad_' .. field, record)
    end
    api.view('badkey', {
        render = function() end,
        keypress = function() error 'key fails' end,
    })
end
]]))
    local cfg = {plugins = {directory = dir, modules = {'badviews'}}, networks = {}}
    local ok, err = pcall(function()
        T.boot {strict = false, ui = true, config = cfg}
        local control = T.require 'hub.ui.control'
        local function draw() HUB.current.routes['ui.draw']() end

        for _, field in ipairs {'render', 'status', 'modes'} do
            local id = 'bad_' .. field
            local before = #T.log_lines 'error'
            HUB.test_calls = 0
            control.set_view(id)
            for _ = 1, 3 do draw() end
            T.eq(HUB.test_calls, 1, id .. ' is not run again')
            local logged = T.log_lines 'error'
            T.eq(#logged, before + 1, id .. ' is reported once')
            T.ok(logged[#logged]:find('plugin badviews view ' .. id .. ': ', 1, true), logged[#logged])
            T.eq(HUB.state.ui.view, id, id .. ' stays selected, saying so')
        end

        -- a key's failure is reported, and the view stays
        control.set_view 'badkey'
        draw()
        local record = HUB.current.views.badkey
        HUB.current.routes['ui.entry']('on_keyboard', string.byte 'x')
        local logged = T.log_lines 'error'
        T.ok(logged[#logged]:find('plugin badviews view badkey: ', 1, true), logged[#logged])
        T.eq(HUB.current.views.badkey, record, 'not disabled')

        -- built-in views fail the same way
        local before = #T.log_lines 'error'
        break_help()
        control.set_view 'help'
        for _ = 1, 3 do draw() end
        logged = T.log_lines 'error'
        T.eq(#logged, before + 1, 'a built-in view is reported once')
        T.ok(logged[#logged]:find('view help: ', 1, true), logged[#logged])

        T.ok(T.reload {config = cfg}, 'reload')
        HUB.test_calls = 0
        control.set_view 'bad_render'
        draw()
        T.eq(HUB.test_calls, 1, 'a reload tries a disabled view again')
        control.set_view 'help'
        before = #T.log_lines 'error'
        draw()
        T.eq(#T.log_lines 'error', before, 'and a built-in one works again')

        -- strict mode still raises, so a test can't miss a view that fails
        T.boot {ui = true, config = {networks = {}}}
        break_help()
        T.require 'hub.ui.control'.set_view 'help'
        T.eq((pcall(HUB.current.routes['ui.draw'])), false, 'strict raises')
    end)
    os.remove(path.join(dir, 'badviews.lua'))
    if not ok then error(err, 0) end
end)

T.case('every failure is in the status view; /plugins says one failed and links there', function()
    assert(file.write(path.join(dir, 'nostart.lua'), [[error 'never starts']]))
    local ok, err = pcall(function()
        T.boot {strict = false, ui = true, config = {plugins = {directory = dir, modules = {'nostart'}}, networks = {}}}
        local logged = T.log_lines 'error'
        T.eq(#logged, 1, 'logged as an error like any other')
        T.ok(logged[1]:find('^plugin nostart start: ') and logged[1]:find('never starts', 1, true), logged[1])

        local entry
        for e in T.require 'hub.lib.OrderedMap'.each(HUB.state.log) do
            if e.category == 'error' then entry = e end
        end
        T.eq(entry.detail and entry.detail.kind, 'error', 'its traceback is one click away')

        local control = T.require 'hub.ui.control'
        control.set_view 'plugins'
        HUB.current.routes['ui.draw']()
        for y = 0, 3 do
            for x = 0, 60 do
                if HUB.state.ui.view == 'plugins' then
                    HUB.current.routes['ui.entry']('on_mouse', y, x, false)
                end
            end
        end
        T.eq(HUB.state.ui.view, 'status', '[status] goes there')
    end)
    os.remove(path.join(dir, 'nostart.lua'))
    if not ok then error(err, 0) end
end)

-- a case of its own: T.run returns at the first sleep, before later cases
T.case('remove the plugin directory', function()
    for name in pairs(sources) do os.remove(path.join(dir, name .. '.lua')) end
    path.rmdir(dir)
    T.ok(not path.exists(dir), 'removed')
end)

T.run()
