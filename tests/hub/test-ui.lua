-- Command line and prompts, without a terminal. test-views.lua draws the
-- views with a fake ncurses.
--
-- Run with:  snowcone tests/hub/test-ui.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')

local function network(id, extra)
    local net = {id = id, server = {host = id .. '.test', port = 6667}, identity = {nick = 'me'}}
    for k, v in pairs(extra or {}) do net[k] = v end
    return net
end

local function register(c)
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
end

-- Boot headless, with the UI's state and prompt subscription
local function boot(networks)
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = networks}}
    local control = T.require 'hub.ui.control'
    control.init_state(HUB.state)
    local bus = T.require 'hub.runtime.bus'
    bus.on(HUB.current.bus, 'task.prompt', 'test', control.add_prompt)
    return fake, control, T.require 'hub.ui.cmdline'
end

local function last_error()
    local errors = T.log_lines 'error'
    return errors[#errors]
end

T.case('scrub makes C0 and C1 controls visible', function()
    boot {}
    local scrub = T.require 'hub.lib.scrub'
    -- an OSC 9 notification a crafted message tries to end early with ST
    T.eq(scrub 'a\27]9;x\u{9c}b\7', 'a␛]9;x\u{fffd}b␇', 'controls replaced')
    T.eq(scrub 'café\u{a0}ok', 'café\u{a0}ok', 'other text kept')
end)

T.case('net commands use the current network or @network', function()
    local fake, control, cmdline = boot {network('a'), network('b')}
    local ca, cb = fake.conns[1], fake.conns[2]
    register(ca)
    register(cb)

    T.eq(control.current_net(), 'a', 'first network by default')
    cmdline.execute 'quote PRIVMSG x :hello there'
    T.eq(ca:take(), {'PRIVMSG x :hello there'}, 'sent on a')

    cmdline.execute 'quote @b PRIVMSG y :hi'
    T.eq(cb:take(), {'PRIVMSG y hi'}, 'sent on b')
    T.eq(ca:take(), {}, 'not on a')

    control.set_current_net 'b'
    cmdline.execute 'raw PRIVMSG z :raw  spaces '
    T.eq(cb:take(), {'PRIVMSG z :raw  spaces '}, 'raw sent unchanged on the current network')
end)

T.case('command errors are reported briefly', function()
    local _, _, cmdline = boot {network('a')}
    cmdline.execute 'nosuch'
    T.eq(last_error(), 'unknown command: nosuch', 'unknown command')
    cmdline.execute 'quote @zz PING x'
    T.eq(last_error(), 'no such network: zz', 'unknown network')
    cmdline.execute 'quote'
    T.eq(last_error(), 'quote requires: $r', 'missing argument')

    local before = #T.log_lines 'trace'
    T.require 'hub.net.manager'.disconnect 'a'
    cmdline.execute 'quote PING x'
    T.ok(last_error():find('network not connected', 1, true), last_error())
    T.eq(#T.log_lines 'trace', before, 'no traceback for a usage error')

    cmdline.execute 'eval error({}, 1)'
    T.eq(#T.log_lines 'trace', before, 'eval catches its own errors')
end)

T.case('a prompt takes over input and keeps the typed command', function()
    local fake, control, cmdline = boot {network('a', {
        server = {host = 'a.test', port = 6667, password = {prompt = 'server password'}},
    })}
    local editor = T.require 'hub.ui.editor'
    local input = HUB.state.ui.input

    -- a half-typed command when the prompt arrives
    input.mode = 'command'
    for _, c in utf8.codes 'quote PI' do editor.add(input.editor, c) end

    local c = fake.last()
    c:con()
    T.eq(input.mode, 'password', 'prompting')
    T.eq(control.current_prompt().label, 'server password', 'label')
    T.ok(control.editor() == input.secret, 'secret editor in use')

    for _, ch in utf8.codes 'hunter2' do editor.add(control.editor(), ch) end
    control.answer_prompt(editor.content(control.editor()))

    T.eq(input.mode, 'command', 'back to the command line')
    T.eq(editor.content(input.editor), 'quote PI', 'typed command kept')
    T.eq(editor.content(input.secret), '', 'secret cleared')
    T.eq(input.secret.history, {}, 'secret not in history')
    T.eq(c:take(), {'CAP LS 302', 'PASS hunter2', 'NICK me', 'USER me 0 * me'}, 'PASS sent')
    T.eq(cmdline ~= nil, true, 'loaded')
end)

T.case('aborting a prompt fails only that secret', function()
    local fake, control = boot {network('a', {
        server = {host = 'a.test', port = 6667, password = {prompt = 'server password'}},
    })}
    local c = fake.last()
    c:con()
    T.eq(HUB.state.ui.input.mode, 'password', 'prompting')
    control.answer_prompt(nil)
    T.eq(HUB.state.ui.input.mode, nil, 'input mode restored')
    T.eq(c:take(), {'CAP LS 302', 'NICK me', 'USER me 0 * me'}, 'registers without PASS')
    T.ok(T.log_lines('irc')[#T.log_lines 'irc']:find('prompt aborted', 1, true), 'reported')
end)

T.case('a prompt whose task ended is skipped', function()
    local fake, control = boot {network('a', {
        server = {host = 'a.test', port = 6667, password = {prompt = 'server password'}},
    })}
    fake.last():con()
    T.eq(HUB.state.ui.input.mode, 'password', 'prompting')
    fake.last():finish 'reset' -- cancels the registration task
    control.check_prompts()
    T.eq(HUB.state.ui.input.mode, nil, 'prompt dropped')
    T.eq(HUB.state.ui.input.prompts, {}, 'queue empty')
end)

T.case('filters follow the filter input while typing', function()
    local _, control = boot {}
    local editor = T.require 'hub.ui.editor'
    local input = HUB.state.ui.input
    HUB.state.ui.view = 'console'
    control.set_filter('console', 'saved')
    T.eq(control.filter 'console', 'saved', 'saved filter')
    input.mode = 'filter'
    for _, c in utf8.codes 'typing' do editor.add(input.editor, c) end
    T.eq(control.filter 'console', 'typing', 'live filter')
    T.eq(control.filter 'status', nil, 'other views unaffected')

    local matching = T.require 'hub.lib.matching'
    T.ok(matching.safematch('Hello World', 'hello'), 'lower case pattern ignores case')
    T.ok(not matching.safematch('Hello World', 'Hello world'), 'capitals make it case sensitive')
    T.ok(matching.safematch('anything', '('), 'invalid pattern matches everything')
    T.eq(matching.compile '(', nil, 'invalid pattern does not compile')
end)

T.case('editor: line breaks, hex input and history', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local ed = editor.new()
    local function typed(text)
        editor.reset(ed)
        for _, c in utf8.codes(text) do editor.add(ed, c) end
    end

    typed 'a^J'
    editor.hexinput(ed)
    T.eq(editor.content(ed), 'a\n', '^J makes a line break')
    typed 'xa'
    editor.hexinput(ed)
    T.eq(editor.content(ed), '\n', 'x0a too')
    typed 'xZ'
    editor.hexinput(ed)
    T.eq(editor.content(ed), 'xZ', 'not hex: left alone')
    typed 'x0'
    editor.hexinput(ed)
    T.eq(editor.content(ed), 'x0', 'NUL refused')

    typed '/join #ab'
    editor.confirm(ed)
    typed '/join #ba'
    editor.confirm(ed)
    T.eq(#ed.history, 2, 'an anagram of the last line is still new')
    typed '/join #ba'
    editor.confirm(ed)
    T.eq(#ed.history, 2, 'a repeat is not')
end)

T.run()
