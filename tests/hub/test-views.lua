-- Every view draws, with a fake ncurses, after real traffic: the notice
-- fixtures and some chat. Also drives keys through the native entry point.
--
-- Run with:  snowcone script tests/hub/test-views.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local fake_ncurses = dofile(here .. '/fake_ncurses.lua')
local path = require 'pl.path'

fake_ncurses.install(150, 40)
local ncurses = fake_ncurses.ncurses

local function boot()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        servers_file = path.abspath(here .. '/fixtures/servers.lua'),
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CHANTYPES=# MONITOR=100 :are supported'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':srv 221 me +o'
    return c
end

local function key(k)
    HUB.current.routes['ui.entry']('on_keyboard', k)
end

local function type_text(text)
    for _, c in utf8.codes(text) do key(c) end
end

T.case('the UI loads with every module', function()
    boot()
    T.ok(HUB.current.views.cliconn and HUB.current.views.buffer, 'views')
    T.ok(HUB.current.commands.list, 'chat /list, not the view command')
end)

T.case('every view draws after real traffic', function()
    local c = boot()
    for line in io.lines(here .. '/fixtures/snotes-live.log') do
        c:recv(line, false)
    end
    for line in io.lines(here .. '/fixtures/snotes-synthetic.log') do
        if line:sub(1, 1) ~= '#' then c:recv(line, false) end
    end
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :@me +alice bob'
    c:recv ':alice!a@h PRIVMSG #chan :hello \x02bold\x02 \x0304red'
    c:recv ':alice!a@h PRIVMSG #chan :\x01ACTION waves\x01'
    c:recv ':bob!b@h PRIVMSG me :private'
    c:recv ':srv 015 me :alpha.example[01A] ---- | Users:   100 (10%)'
    c:recv ':srv 017 me :End of /MAP'
    c:recv ':srv 322 me #a 12 :topic a'
    HUB.current.routes['app.tick']()

    local control = T.require 'hub.ui.control'
    control.set_talk_target('test', '#chan')
    local ids = {}
    for id in pairs(HUB.current.views) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        control.set_view(id)
        HUB.current.routes['ui.draw']()
        -- scrolled back, too
        control.view_state(id).scroll = 3
        HUB.current.routes['ui.draw']()
        control.view_state(id).scroll = 0
    end
    T.eq(T.log_lines 'error', {}, 'no drawing errors')
end)

T.case('keys reach input modes, views and commands', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    c:take()

    -- a command typed and run
    key(string.byte '/')
    type_text 'talk #chan'
    key(13)
    T.eq(HUB.state.ui.view, 'buffer', 'talk shows the buffer')
    T.eq(control.talk_target 'test', '#chan', 'target')

    -- talk mode sends to the shown buffer
    key(string.byte 't')
    T.eq(HUB.state.ui.input.mode, 'talk', 'talk mode')
    type_text 'hi there'
    key(13)
    local sent = c:take()
    T.eq(sent[#sent], 'PRIVMSG #chan :hi there', 'sent')

    -- tab completes nicks in the channel
    c:recv ':srv 353 me = #chan :@me +alice'
    key(string.byte 't')
    type_text 'ali'
    key(9)
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'alice', 'completed')
    key(0x1b)
    T.eq(HUB.state.ui.input.mode, nil, 'Esc leaves input mode')

    -- Meta-A jumps to a buffer with activity
    c:recv ':bob!b@h PRIVMSG me :ping'
    control.set_view 'console'
    key(-string.byte 'a')
    T.eq({HUB.state.ui.view, control.talk_target 'test'}, {'buffer', 'bob'}, 'jumped')

    -- Ctrl-N steps through buffers in the buffer view
    key(0x1f & string.byte 'N')
    T.eq(control.talk_target 'test', '#chan', 'next buffer')

    -- F1 picks the first view of the rotation
    key(-ncurses.KEY_F1)
    T.eq(HUB.state.ui.view, control.rotation()[1], 'F1')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('pastes go to the editor up to a newline; an oversized one is reported', function()
    boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    key(string.byte '/')
    HUB.current.routes['ui.entry']('on_paste', 'say hi\nsecond line')
    T.eq(editor.content(control.editor()), 'say hi', 'pasted up to the newline')
    HUB.current.routes['ui.entry']('on_paste', nil, 70000)
    T.eq(T.log_lines 'error', {'paste: a paste of 70000 bytes was discarded (limit 64 KiB)'}, 'reported')
    T.eq(editor.content(control.editor()), 'say hi', 'editor unchanged')
end)

T.case('^C and signals quit, then shut down; nothing draws after', function()
    local c = boot()
    c:take()
    key(0x1f & string.byte 'C')
    T.eq(HUB.quitting, true, '^C starts quitting')
    T.ok(c:take()[1]:find('^QUIT'), 'QUIT sent')
    T.eq(HUB.shut_down, nil, 'still waiting for the server')
    HUB.current.routes['ui.entry']('on_signal', 'SIGTERM')
    T.eq(HUB.shut_down, true, 'a second signal shuts down')
    T.eq(T.log_lines 'app'[#T.log_lines 'app'], 'received SIGTERM', 'logged')

    local drew = false
    HUB.current.routes['ui.draw'] = function() drew = true end
    T.require 'hub.runtime.dispatch'.dirty()
    T.require 'hub.runtime.dispatch'.flush()
    T.eq(drew, false, 'no drawing after shutdown')
end)

T.case('a staged K-Line turns the title red', function()
    boot()
    local statusbar = T.require 'hub.ui.statusbar'
    local oper = T.require 'hub.features.oper'
    T.eq(statusbar.title_colour(), ncurses.COLOR_WHITE, 'white normally')
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    T.eq(statusbar.title_colour(), ncurses.COLOR_RED, 'red with a K-Line staged')
    oper.cancel 'test'
    T.eq(statusbar.title_colour(), ncurses.COLOR_WHITE, 'white once cancelled')
    oper.stage_undline('test', '198.51.100.0/24')
    T.eq(statusbar.title_colour(), ncurses.COLOR_WHITE, 'only K-Lines')
end)

T.case('the console inspector decodes server notices', function()
    local c = boot()
    local line = ':gold.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [Real]'
    c:recv(line)
    local msg = T.require 'hub.lib.OrderedMap'.lookup(HUB.state.nets.test.console, true)
    local console = HUB.current.views.console
    local note = console.decode(msg)
    T.eq({note.name, note.nick, note.ip, note.server}, {'connect', 'n', '192.0.2.1', 'gold.example'}, 'decoded')
    T.eq(console.decode(snowcone.parse_irc ':srv 001 me :Welcome'), nil, 'not a notice')

    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    control.view_state('console').focus = msg
    HUB.current.routes['ui.draw']()
    control.view_state('console').show_raw = true
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.run()
