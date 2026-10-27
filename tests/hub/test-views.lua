-- Every view draws, with a fake ncurses, after real traffic: the notice
-- fixtures and some chat. Also drives keys through the native entry point.
--
-- Run with:  snowcone tests/hub/test-views.lua

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

T.case('every view draws with no networks configured', function()
    T.boot {ui = true, config = {networks = {}}}
    HUB.current.routes['app.tick']()
    local control = T.require 'hub.ui.control'
    local ids = {}
    for id in pairs(HUB.current.views) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        control.set_view(id)
        HUB.current.routes['ui.draw']()
        key(-ncurses.KEY_NPAGE)
        key(0x1b)
        HUB.current.routes['ui.draw']()
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

    -- Meta-H hides joins and the like in the buffer view
    c:recv ':carol!c@h JOIN #chan'
    key(-string.byte 'h')
    T.eq(control.view_state 'buffer'.hide_presence, true, 'presence hidden')
    HUB.current.routes['ui.draw']()
    key(-string.byte 'h')
    T.eq(control.view_state 'buffer'.hide_presence, false, 'presence shown')

    -- F1 picks the first view of the rotation
    key(-ncurses.KEY_F1)
    T.eq(HUB.state.ui.view, control.rotation()[1], 'F1')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('closing the shown buffer moves to a mention, back, activity, then the next', function()
    local c = boot()
    local chat = T.require 'hub.features.chat'
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, chan in ipairs {'#a', '#b', '#c', '#d'} do
        c:recv(':me!u@h JOIN ' .. chan)
    end
    for _, chan in ipairs {'#a', '#b', '#c', '#d'} do
        chat.look(chat.buffer('test', chan))
    end
    local function shown() return control.talk_target 'test' end
    local function close() cmdline.execute 'close' end

    cmdline.execute 'talk #b'
    cmdline.execute 'talk #c'
    c:recv ':bob!b@h PRIVMSG #a :hello'
    c:recv ':carol!c@h PRIVMSG me :psst'

    close()
    T.eq(shown(), 'carol', 'a mention first')
    T.eq(control.view_state 'buffer'.previous.test, '#b', 'Meta-S still goes back')
    HUB.current.routes['ui.draw']()
    close()
    T.eq(shown(), '#b', 'then back to the previous one')
    T.eq(control.view_state 'buffer'.previous.test, nil, 'which is no longer previous')
    close()
    T.eq(shown(), '#a', 'then activity')
    HUB.current.routes['ui.draw']()
    close()
    T.eq(shown(), '#d', 'then the next by name')
    close()
    T.eq(shown(), nil, 'none left')

    -- closing another buffer leaves the shown one
    c:recv ':me!u@h JOIN #f'
    c:recv ':me!u@h JOIN #g'
    cmdline.execute 'talk #f'
    cmdline.execute 'close #g'
    T.eq(shown(), '#f', 'unchanged')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('closing a query visited with Meta-A goes back to the channel', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':me!u@h JOIN #busy'
    cmdline.execute 'talk #chan'
    HUB.current.routes['ui.draw']()

    c:recv ':bob!b@h PRIVMSG me :got a minute?'
    key(-string.byte 'a')
    T.eq(control.talk_target 'test', 'bob', 'to the query')
    HUB.current.routes['ui.draw']()
    c:recv ':alice!a@h PRIVMSG #busy :chatter'
    c:recv ':alice!a@h PRIVMSG #chan :chatter'
    cmdline.execute 'close'
    T.eq(control.talk_target 'test', '#chan', 'back where I was')
end)

T.case('the paging keys scroll any rolling view within its log', function()
    boot()
    local control = T.require 'hub.ui.control'
    local log = T.require 'hub.runtime.log'
    for i = 1, 100 do log.add('test', 'line %d', i) end
    control.set_view 'status'
    HUB.current.routes['ui.draw']()
    local vs = control.view_state 'status'
    local size = T.require 'hub.lib.OrderedMap'.size(HUB.state.log)
    -- 40 rows: the title, 38 rows of log (one the divider), the input line
    key(-ncurses.KEY_PPAGE)
    T.eq(vs.scroll, 36, 'a page keeps one entry in view')
    for _ = 1, 5 do key(-ncurses.KEY_PPAGE) end
    T.eq(vs.scroll, size - 37, 'stops with the oldest entry in view')
    key(-ncurses.KEY_DOWN)
    T.eq(vs.scroll, size - 38, 'a line')
    for _ = 1, 5 do key(-ncurses.KEY_NPAGE) end
    T.eq(vs.scroll, 0, 'back to the newest')
end)

-- The pad document views draw into: the newest one as wide as the screen
local function document_pad()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.w == tty_width then return win end
    end
end

-- Rows of a window, from its top
local function rows_of(win)
    local rows = {}
    for y = 0, win.y do rows[y] = fake_ncurses.row(win, y) end
    return rows
end

-- The text of the status bar as last drawn
local function status_bar()
    HUB.current.routes['ui.draw']()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newwin' and win.h == 1 and win.w == tty_width then
            return fake_ncurses.row(win, 0)
        end
    end
end

T.case('a document view grows to its whole length and pages down from the top', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'help'
    key(-string.byte 'a') -- every feature's commands: longer than a screen
    HUB.current.routes['ui.draw']()
    local vs = control.view_state 'help'
    local pad = document_pad()
    T.ok(pad.h > tty_height, 'the pad grew past the screen')
    T.ok(pad.y < pad.h - 1, 'and holds every row')
    T.eq(vs.max_scroll, pad.y - (tty_height - 1), 'scrolls until the last row shows')

    T.ok(not status_bar():find 'scroll', 'no position at the top')

    key(-ncurses.KEY_NPAGE)
    T.eq(vs.scroll, math.min(tty_height - 2, vs.max_scroll), 'PgDn moves down a page less a row')
    T.ok(status_bar():find(string.format('scroll %d/%d', vs.scroll, vs.max_scroll), 1, true), 'position once down')
    HUB.current.routes['ui.draw']()
    T.eq(pad.top, vs.scroll, 'shown from that row')
    for _ = 1, 50 do key(-ncurses.KEY_NPAGE) end
    T.eq(vs.scroll, vs.max_scroll, 'stops at the end')
    key(-ncurses.KEY_UP)
    T.eq(vs.scroll, vs.max_scroll - 1, 'up a line')
    key(0x1b)
    T.eq(vs.scroll, 0, 'Esc returns to the top')
end)

T.case('the status bar shows the modes of the view as one fragment', function()
    boot()
    local control = T.require 'hub.ui.control'
    local sep = T.require 'hub.ui.statusbar'.thin_separator
    control.set_view 'console'
    T.ok(not status_bar():find 'hide', 'none by default')

    key(-string.byte 'h')
    key(-string.byte 'r')
    control.view_state 'console'.scroll = 3
    control.view_state 'console'.filter = 'x'
    T.ok(status_bar():find(' hide raw scroll 3 filter "x" ' .. sep, 1, true), 'in order, together')

    control.view_state 'console'.hscroll = 16
    T.ok(status_bar():find(' scroll 3,+16 ', 1, true), 'horizontal scroll')
end)

T.case('session lists show one row and expand on a click', function()
    local c = boot()
    local tokens = {}
    for i = 1, 60 do table.insert(tokens, string.format('TOKEN%02d=value', i)) end
    c:recv(':srv 005 me ' .. table.concat(tokens, ' ') .. ' :are supported')
    local control = T.require 'hub.ui.control'
    control.set_view 'session'

    local function isupport()
        HUB.current.routes['ui.draw']()
        local rows, found = rows_of(document_pad()), {}
        for y = 0, #rows do
            if rows[y]:find '^%s*isupport: ' then
                found[1] = y
            elseif found[1] and rows[y]:find '^%s*%w+: ' then
                break
            end
            if found[1] then table.insert(found, rows[y]) end
        end
        return found
    end

    local folded = isupport()
    T.eq(#folded, 2, 'one row')
    local text = folded[2]
    local more = text:match '%[%+(%d+) more%]%s*$'
    T.ok(more, 'ends in an expand button: ' .. text)
    T.ok(#text <= tty_width, 'within the screen')

    -- click the button
    local x = text:find('[+', 1, true) - 1
    HUB.current.routes['ui.entry']('on_mouse', folded[1], x, false)
    local open = isupport()
    T.ok(#open > 2, 'several rows')
    T.ok(open[#open]:find '%[less%]%s*$', 'ends in a fold button')
    T.ok(open[#open]:find 'TOKEN60', 'shows the last token')

    key(0x1b)
    T.eq(#isupport(), 2, 'Esc folds it again')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('an expanded list indents every row, even after one that fills the width', function()
    boot()
    local fields = T.require 'hub.ui.fields'
    -- three 4-letter words and their spaces fill a 26-column row exactly
    local cols = fields.width + 2 + 3 * 5 - 1
    for _, n in ipairs {7, 8} do
        local win = ncurses.newpad(20, cols)
        local ctx = {cols = cols, vs = {expanded = {t = true}}, add_button = function(w, text) w:waddstr(text) end}
        local list = {}
        for i = 1, n do table.insert(list, string.rep(string.char(96 + i), 4)) end
        fields.label(win, 't')
        fields.words(ctx, win, 't', list)
        local rows = rows_of(win)
        T.ok(#rows > 1, 'wrapped')
        for y = 1, #rows - 1 do
            T.ok(rows[y]:find('^' .. string.rep(' ', fields.width + 2) .. '[%w%[]'), 'row ' .. y .. ' indented: ' .. rows[y])
        end
    end
end)

T.case("Esc resets the view's own filters too", function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'cliconn'
    local vs = control.view_state 'cliconn'
    vs.scroll, vs.filter, vs.server_filter, vs.conn_filter = 2, 'x', 'srv', true
    key(0x1b)
    T.eq({vs.scroll, vs.filter, vs.server_filter, vs.conn_filter}, {0}, 'cleared')
    T.ok(HUB.current.commands.prefilter, 'the connection views bring /prefilter')
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
