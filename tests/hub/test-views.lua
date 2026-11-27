-- Every view draws, with a fake ncurses, after real traffic: the notice
-- fixtures and some chat; and what views show as they follow it.
--
-- Run with:  snowcone tests/hub/test-views.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local V = dofile(here .. '/viewlib.lua')(T, here)
local FakeTransport, fake_ncurses, path, ncurses = V.FakeTransport, V.fake_ncurses, V.path, V.ncurses
local boot, key, type_text, detail_pad, rows_of = V.boot, V.key, V.type_text, V.detail_pad, V.rows_of
local has_row, status_bar = V.has_row, V.status_bar

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
    local talk = T.require 'hub.ui.talk'
    talk.set_target('test', '#chan')
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

T.case('the first view is one the network has the features for', function()
    T.boot {ui = true, transport = FakeTransport.new(), config = {networks = {{
        id = 'chatty',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        features = {'chat'},
    }}}}
    T.eq(HUB.state.ui.view, 'buffer', 'not a dashboard view')
    local control = T.require 'hub.ui.control'
    T.eq(control.rotation(), {'console', 'buffer', 'networks', 'status'}, 'no dashboard views to step through')
    key(-ncurses.KEY_F1)
    T.eq(HUB.state.ui.view, 'console', 'F1 is the first left')

    T.boot {ui = true, transport = FakeTransport.new(), config = {networks = {{
        id = 'plain',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
        features = {},
    }}}}
    T.eq(HUB.state.ui.view, 'console', 'no features: the first general view')
end)

T.case('a view the network lacks the feature for gives way to its first view', function()
    local function config(chatty_features)
        return {networks = {
            {id = 'full', server = {host = 'a.example', port = 6667}, identity = {nick = 'me'}},
            {id = 'chatty', server = {host = 'b.example', port = 6667}, identity = {nick = 'me'},
             features = chatty_features},
        }}
    end
    T.boot {ui = true, transport = FakeTransport.new(), config = config {'chat'}}
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    T.eq(HUB.state.ui.view, 'cliconn', 'the first network has notices')

    control.set_current_net 'chatty'
    T.eq(HUB.state.ui.view, 'buffer', 'switching networks leaves cliconn')

    cmdline.execute 'cliconn'
    T.eq(HUB.state.ui.view, 'buffer', 'not shown for a network without notices')
    T.eq(#T.log_lines 'error', 1, 'and says why')
    T.ok(not cmdline.available(HUB.current.commands.cliconn), 'nor offered')

    cmdline.execute 'cliconn@full'
    T.eq({control.current_net(), HUB.state.ui.view}, {'full', 'cliconn'}, 'shown with its network')

    control.set_view 'console'
    control.set_current_net 'chatty'
    T.eq(HUB.state.ui.view, 'console', 'a general view stays')

    control.set_view 'buffer'
    T.reload {config = config {}}
    T.eq(HUB.state.ui.view, 'console', 'a reload that drops the feature moves on')
end)

T.case('/addwatch filter takes the filter of the cliconn view', function()
    boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    local watches = T.require 'hub.features.snotice.stores'.get('test').watches
    local before = #watches

    cmdline.execute 'addwatch filter'
    T.eq(#watches, before, 'nothing without a filter')
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find 'cliconn filter', 'and says why')

    control.set_filter('cliconn', 'badguy')
    cmdline.execute 'addwatch filter red'
    T.eq({watches[#watches].pattern, watches[#watches].color}, {'badguy', 'red'}, 'added')
end)

T.case('without the oper feature, masks stage nothing when clicked', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test', features = {'snotice', 'chat'},
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':srv 221 me +o'
    c:recv ':a.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [g]'
    c:take()
    T.require 'hub.ui.control'.set_view 'cliconn'
    HUB.current.routes['ui.draw']()
    for y = 0, tty_height - 1 do
        HUB.current.routes['ui.entry']('on_mouse', y, 20, false)
    end
    T.eq(c:take(), {}, 'no TESTMASK')
    T.eq(HUB.state.features.oper, nil, 'no oper state')
end)

T.case('a terminal of one row still draws', function()
    boot()
    local height = tty_height
    local made = {}
    rawset(_G, 'tty_height', 1)
    local ok, err = pcall(function()
        HUB.current.routes['ui.entry']('on_resize')
        for _, win in ipairs(fake_ncurses.windows) do
            if win.kind == 'newpad' then table.insert(made, win.h) end
        end
        for _, view in ipairs {'status', 'console', 'cliconn', 'buffer'} do
            T.require 'hub.ui.control'.set_view(view)
            HUB.current.routes['ui.draw']()
        end
    end)
    rawset(_G, 'tty_height', height)
    HUB.current.routes['ui.entry']('on_resize')
    assert(ok, err)
    T.ok(made[#made] >= 1, 'no pad of zero rows')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('times from a server that are not times show as ?', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 332 me #chan :a topic'
    c:recv ':srv 333 me #chan op 99999999999999999999'
    c:recv ':srv 329 me #chan 1.5'
    c:recv ':srv 367 me #chan *!*@x op nonsense'
    c:recv ':srv 368 me #chan :End'
    T.command('chaninfo #chan', 'test', '#chan')
    HUB.current.routes['ui.draw']()
    c:recv ':srv 317 me bob 1e999 1.5 :seconds idle, signon time'
    local log = HUB.state.nets.test.console
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    control.open_detail('message', 'test', OrderedMap.get(log, OrderedMap.last(log)))
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
    local draw = T.require 'hub.ui.draw'
    T.eq({draw.date('%c', 1.5), draw.date('%c', 'x'), draw.duration(1/0), draw.duration(0/0)}, {'?', '?', '?', '?'}, '?')
    T.eq({draw.date('%Y', 0), draw.duration(90)}, {os.date('%Y', 0), '90s'}, 'sane ones as before')
end)

T.case('closing the shown buffer moves to a mention, back, activity, then the next', function()
    local c = boot()
    local chat = T.require 'hub.features.chat'
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, chan in ipairs {'#a', '#b', '#c', '#d'} do
        c:recv(':me!u@h JOIN ' .. chan)
    end
    for _, chan in ipairs {'#a', '#b', '#c', '#d'} do
        chat.look(chat.buffer('test', chan))
    end
    local function shown() return talk.target 'test' end
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
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':me!u@h JOIN #busy'
    cmdline.execute 'talk #chan'
    HUB.current.routes['ui.draw']()

    c:recv ':bob!b@h PRIVMSG me :got a minute?'
    key(-string.byte 'a')
    T.eq(talk.target 'test', 'bob', 'to the query')
    HUB.current.routes['ui.draw']()
    c:recv ':alice!a@h PRIVMSG #busy :chatter'
    c:recv ':alice!a@h PRIVMSG #chan :chatter'
    cmdline.execute 'close'
    T.eq(talk.target 'test', '#chan', 'back where I was')
end)

T.case('Meta-A leaves the shown buffer, its activity not drawn yet', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    T.require 'hub.runtime.pace'.interval = 60
    c:recv ':me!u@h JOIN #busy'
    cmdline.execute 'talk bob'
    HUB.current.routes['ui.draw']()
    HUB.drawn_at = T.require 'hub.runtime.clock'.now()

    c:recv ':alice!a@h PRIVMSG #busy :chatter'
    c:recv ':bob!b@h PRIVMSG me :hello'
    local bob = T.require 'hub.features.chat'.buffer('test', 'bob')
    T.eq(bob.mention, true, 'not drawn yet')
    key(-string.byte 'a')
    T.eq(talk.target 'test', '#busy', 'to the other buffer')

    -- from another view, the mention goes first, in the target too
    talk.set_target('test', 'bob')
    control.set_view 'console'
    key(-string.byte 'a')
    T.eq({HUB.state.ui.view, talk.target 'test'}, {'buffer', 'bob'}, 'to the mention')
end)

T.case('views follow their events once, after a reload too', function()
    local c = boot()
    T.ok(T.reload(), 'reloaded')
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, topic in ipairs {'chat.focus', 'chat.buffer', 'chat.show_channel'} do
        local n = 0
        for _, s in ipairs(HUB.current.bus.topics[topic]) do
            if s.owner == 'hub.ui' then n = n + 1 end
        end
        T.eq(n, 1, topic .. ': one subscription')
    end

    c:recv ':me!u@h JOIN #a'
    c:recv ':me!u@h JOIN #b'
    control.set_view 'console'
    cmdline.execute 'talk #a'
    T.eq({HUB.state.ui.view, talk.target 'test'}, {'buffer', '#a'}, '/talk shows the buffer')
    cmdline.execute 'close'
    T.eq(talk.target 'test', '#b', 'closing the shown buffer moves on')
end)

T.case('the shown buffer is marked seen only while the terminal has focus', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local chat = T.require 'hub.features.chat'
    local tty = T.require 'hub.runtime.tty'
    c:recv ':bob!b@h PRIVMSG me :first'
    talk.set_target('test', 'bob')
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    local buffer = chat.buffer('test', 'bob')
    T.eq(buffer.activity, 0, 'seen when shown with focus')

    tty.set_focus(false)
    c:recv ':bob!b@h PRIVMSG me :while away'
    HUB.current.routes['ui.draw']()
    T.eq({buffer.activity, buffer.mention}, {1, true}, 'unseen while unfocused')
    tty.set_focus(true)
    HUB.current.routes['ui.draw']()
    T.eq({buffer.activity, buffer.mention}, {0, false}, 'seen on return')
end)

T.case('the terminal title names the view and marks unseen chat', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local tty = T.require 'hub.runtime.tty'
    local function draw()
        HUB.current.routes['ui.draw']()
        return HUB.tty_title
    end

    control.set_view 'status'
    T.eq(draw(), 'snowcone - test status', 'a view by its title')

    c:recv ':me!u@h JOIN #chan'
    c:recv ':bob!b@h PRIVMSG me :hi'
    talk.set_target('test', 'bob')
    control.set_view 'buffer'
    T.eq(draw(), 'snowcone - test bob', 'the buffer view by its target')

    tty.set_focus(false)
    c:recv ':alice!a@h PRIVMSG #chan :hello'
    T.eq(draw(), '+ snowcone - test bob', 'unseen activity first')
    c:recv ':bob!b@h PRIVMSG me :still there?'
    T.eq(draw(), '! snowcone - test bob', 'a mention outranks activity')
    tty.set_focus(true)
    T.eq(draw(), '+ snowcone - test bob', 'the shown buffer is seen, the channel is not')

    talk.set_target('test', '#chan')
    T.eq(draw(), 'snowcone - test #chan', 'all seen')
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

-- What a rotating log of {text} entries shows, newest first, drawn into
-- a window of `rows` rows
local function rotation(vs, om, rows, show)
    local win = ncurses.newwin(rows, 80)
    T.require 'hub.ui.draw'.draw_rotation(win, vs, 0, rows, om, show, function(w, entry)
        w:waddstr('|' .. entry.text)
    end)
    -- rows from the divider up, wrapping round
    local divider
    for y = 0, rows - 1 do
        if not fake_ncurses.row(win, y):find('|', 1, true) then divider = y end
    end
    local list = {}
    for i = 1, rows - 1 do
        local text = fake_ncurses.row(win, (divider - i) % rows):match '|([^·]*)'
        if text then table.insert(list, text) end
    end
    return list
end

T.case('a scrolled rolling view stays put, counting the entries it shows', function()
    boot()
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local om = OrderedMap.new(100)
    local function add(text) OrderedMap.insert(om, nil, {text = text, time = '00:00:00', timestamp = 0}) end
    for i = 1, 40 do add((i % 2 == 0 and 'foo ' or 'bar ') .. i) end
    local vs = {scroll = 0}
    local foo = function(entry) return entry.text:find 'foo' ~= nil end

    T.eq(rotation(vs, om, 5, foo), {'foo 40', 'foo 38', 'foo 36', 'foo 34'}, 'the newest matches')
    T.eq(vs.max_scroll, 16, 'the limit counts matches: 20 less a window of 4')
    vs.scroll = 4
    T.eq(rotation(vs, om, 5, foo), {'foo 32', 'foo 30', 'foo 28', 'foo 26'}, 'a page back is four matches')
    for i = 41, 60 do add('bar ' .. i) end
    T.eq(rotation(vs, om, 5, foo), {'foo 32', 'foo 30', 'foo 28', 'foo 26'}, 'unmoved by others')
    add 'foo 61'
    T.eq(rotation(vs, om, 5, foo), {'foo 32', 'foo 30', 'foo 28', 'foo 26'}, 'and by matches')

    -- emptied and refilled while scrolled
    OrderedMap.reset(om)
    for i = 1, 8 do add('new ' .. i) end
    T.eq(rotation(vs, om, 5), {'new 4', 'new 3', 'new 2', 'new 1'}, 'from the newest, once each')
    vs.scroll = 0
    T.eq(rotation(vs, om, 5), {'new 8', 'new 7', 'new 6', 'new 5'}, 'and unscrolled')
end)

T.case('Ctrl-L lays a rolling view out from the top', function()
    boot()
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local om = OrderedMap.new(100)
    local function add(text) OrderedMap.insert(om, nil, {text = text, time = '00:00:00', timestamp = 0}) end
    local rows = 5
    -- the text on each row, '-' for the divider, '' for an empty row
    local function screen(vs)
        -- as wide as the divider, which a view's pad holds unwrapped
        local win = ncurses.newwin(rows, 1000)
        T.require 'hub.ui.draw'.draw_rotation(win, vs, 0, rows, om, nil, function(w, entry)
            w:waddstr('|' .. entry.text)
        end)
        local out = {}
        for y = 0, rows - 1 do
            local row = fake_ncurses.row(win, y)
            out[y + 1] = row:match '|([^·]*)' or (row:find('·', 1, true) and '-') or ''
        end
        return out
    end
    for i = 1, 7 do add('m' .. i) end
    local vs = {scroll = 3}

    vs.scroll, vs.realign = 0, true
    T.eq(screen(vs), {'m4', 'm5', 'm6', 'm7', '-'}, 'oldest at the top, newest above the divider')
    T.eq(vs.realign, nil, 'once')
    add 'm8'
    T.eq(screen(vs), {'-', 'm5', 'm6', 'm7', 'm8'}, 'the next finishes the screen')
    add 'm9'
    T.eq(screen(vs), {'m9', '-', 'm6', 'm7', 'm8'}, 'then they start from the top')

    -- with too few to fill it, they start at the top
    OrderedMap.reset(om)
    add 'a'
    add 'b'
    vs.realign = true
    T.eq(screen(vs), {'a', 'b', '-', '', ''}, 'a short log')
    add 'c'
    T.eq(screen(vs), {'a', 'b', 'c', '-', ''}, 'continues below')
end)

T.case('choosing another network unscrolls its views', function()
    boot()
    local control = T.require 'hub.ui.control'
    local vs = control.view_state 'console'
    vs.scroll, vs.pin = 3, 10
    local status = control.view_state 'status'
    status.scroll = 2
    control.set_current_net 'test'
    T.eq({vs.scroll, vs.pin}, {3, 10}, 'the same network: kept')
    HUB.state.ui.current_net = 'other'
    control.set_current_net 'test'
    T.eq({vs.scroll, vs.pin}, {0}, 'a network view unscrolled')
    T.eq(status.scroll, 2, 'a global view kept')
end)

-- The pad document views draw into: the newest one as wide as the screen
-- (the detail pane's is made before it)
local function document_pad()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.w == tty_width then return win end
    end
end

T.case('a shown query follows its nick, and Meta-S still goes back', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':bob!b@h PRIVMSG me :hi'
    cmdline.execute 'talk #chan'
    cmdline.execute 'talk bob'
    c:recv ':bob!b@h NICK zed'
    T.eq(talk.target 'test', 'zed', 'still shown')
    T.ok(status_bar():find('zed', 1, true), 'by its new name')
    key(-string.byte 's')
    T.eq(talk.target 'test', '#chan', 'back')
    key(-string.byte 's')
    T.eq(talk.target 'test', 'zed', 'and back to it by its new name')
end)

T.case('j lists the buffers to jump to by labels they keep', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, chan in ipairs {'#a', '#b', '#c'} do
        c:recv(':me!u@h JOIN ' .. chan)
    end
    c:recv ':bob!b@h PRIVMSG me :hi'
    cmdline.execute 'talk #a'
    cmdline.execute 'talk #c'
    control.set_view 'buffer'
    local function pane()
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad())
    end

    key(string.byte 'j')
    T.eq(control.detail().kind, 'jump', 'opened')
    local rows = pane()
    -- Meta-A goes to bob, the one with a mention; Meta-S back to #a
    T.ok(has_row(rows, '^0←#a  1 #b  2 #c  3→bob$'), table.concat(rows, '\n', 0, #rows))

    -- an unassigned label is taken and does nothing
    key(string.byte 'z')
    T.eq({control.detail().kind, HUB.state.ui.input.mode}, {'jump', nil}, 'swallowed')

    -- closing #b frees its label for the next buffer; the rest keep theirs,
    -- a rename too
    cmdline.execute 'close #b'
    c:recv ':bob!b@h NICK zed'
    c:recv ':me!u@h JOIN #new'
    rows = pane()
    T.ok(has_row(rows, '^0←#a  2 #c  1 #new  3→zed$'), table.concat(rows, '\n', 0, #rows))

    -- a label jumps there and closes the pane
    key(string.byte '3')
    T.eq({control.detail(), talk.target 'test', HUB.state.ui.view}, {nil, 'zed', 'buffer'}, 'jumped')

    -- the columns are as wide as their widest names
    control.open_detail('jump', 'test', {})
    for i = 1, 40 do c:recv(string.format(':me!u@h JOIN #chan%02d', i)) end
    c:recv(':me!u@h JOIN #' .. string.rep('x', 40))
    rows = pane()
    T.ok(has_row(rows, ' I #' .. string.rep('x', 22) .. '…$'), table.concat(rows, '\n', 0, #rows))
    T.ok(#rows < 10, 'in columns')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('configured buffers keep their labels, have none, or are left out of the jump pane', function()
    local c = boot {
        {name = '#pinned', label = '0'}, {name = '#later', label = '1'},
        {name = '#nolabel', label = false}, {name = '#hidden', hidden = true},
    }
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    for _, chan in ipairs {'#a', '#hidden', '#nolabel', '#pinned'} do
        c:recv(':me!u@h JOIN ' .. chan)
    end
    control.set_view 'buffer'
    control.open_detail('jump', 'test', {})
    local function pane()
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad())
    end

    -- #a skips 1, kept for #later, which isn't open
    local rows = pane()
    T.ok(has_row(rows, '^2 #a  ' .. '  #nolabel  0 #pinned$'), table.concat(rows, '\n', 0, #rows))
    c:recv ':me!u@h JOIN #later'
    rows = pane()
    T.ok(has_row(rows, '1 #later'), table.concat(rows, '\n', 0, #rows))

    key(string.byte '0')
    T.eq(talk.target 'test', '#pinned', 'jumped by the configured label')

    -- a hidden buffer isn't shown, but its label, 3 after #a's, works
    control.open_detail('jump', 'test', {})
    key(string.byte '3')
    T.eq({control.detail(), talk.target 'test'}, {nil, '#hidden'}, 'jumped to the hidden buffer')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('a reload moves labels to newly configured buffers, and others take free ones', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    for _, chan in ipairs {'#a', '#b', '#c'} do
        c:recv(':me!u@h JOIN ' .. chan)
    end
    control.set_view 'buffer'
    control.open_detail('jump', 'test', {})
    local function pane()
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad())
    end
    local function reload(buffers)
        T.ok(T.reload {config = {networks = {{
            id = 'test',
            server = {host = 'test.example', port = 6667},
            identity = {nick = 'me'},
            servers_file = path.abspath(here .. '/fixtures/servers.toml'),
            buffers = buffers,
        }}}}, 'reloaded')
    end
    local rows = pane()
    T.ok(has_row(rows, '^0 #a  1 #b  2 #c$'), table.concat(rows, '\n', 0, #rows))

    -- #c takes 0 from #a, and #a takes 3, as 1 and 2 are #b's and the
    -- unopened #d's
    reload {{name = '#c', label = '0'}, {name = '#d', label = '2'}}
    rows = pane()
    T.ok(has_row(rows, '^3 #a  1 #b  0 #c$'), table.concat(rows, '\n', 0, #rows))

    -- a hidden buffer keeps its label, so no other takes it
    reload {{name = '#c', hidden = true}}
    c:recv ':me!u@h JOIN #e'
    rows = pane()
    T.ok(has_row(rows, '^3 #a  1 #b  2 #e$'), table.concat(rows, '\n', 0, #rows))
    reload {}
    rows = pane()
    T.ok(has_row(rows, '^3 #a  1 #b  0 #c  2 #e$'), table.concat(rows, '\n', 0, #rows))
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

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

T.case('the status bar names the two who last started typing', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    ---@diagnostic disable-next-line: duplicate-set-field
    clock.now = function() return now end
    c:recv ':me!u@h JOIN #chan'
    talk.set_target('test', '#chan')
    control.set_view 'buffer'
    T.ok(not status_bar():find('…', 1, true), 'nobody typing')

    c:recv '@+typing=active :alice!a@h TAGMSG #chan'
    now = now + 1
    c:recv '@+typing=active :bob!b@h TAGMSG #chan'
    now = now + 1
    c:recv '@+typing=active :carol!c@h TAGMSG #chan'
    c:recv '@+typing=active :alice!a@h TAGMSG #chan'
    T.ok(status_bar():find(' carol, bob… ', 1, true), 'the latest two; a refresh is no change')

    now = now + 1
    c:recv '@+typing=paused :carol!c@h TAGMSG #chan'
    T.ok(status_bar():find(' bob, alice… ', 1, true), 'not those who paused')

    now = now + 6
    T.ok(not status_bar():find('…', 1, true), 'gone once they lapse')
end)

T.case('the buffer view with none chosen shows one with activity, else the first', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    c:recv ':me!u@h JOIN #a'
    c:recv ':me!u@h JOIN #b'
    c:recv ':me!u@h JOIN #c'
    c:recv ':alice!a@h PRIVMSG #b :hello'
    T.eq(talk.target 'test', nil, 'joining chooses none')
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    T.eq(talk.target 'test', '#b', 'the one with activity')

    talk.set_target('test', nil)
    HUB.current.routes['ui.draw']()
    T.eq(talk.target 'test', '#a', 'with none active, the first by name')

    talk.set_target('test', '#gone')
    HUB.current.routes['ui.draw']()
    T.eq(talk.target 'test', '#gone', 'one chosen is kept, open or not')
end)

T.case('the status bar shows the modes of the view as one fragment', function()
    boot()
    local control = T.require 'hub.ui.control'
    local sep = T.require 'hub.ui.statusbar'.thin_separator
    control.set_view 'console'
    T.ok(not status_bar():find 'hide', 'none by default')

    key(-string.byte 'h')
    key(-string.byte 'g')
    control.view_state 'console'.scroll = 3
    control.view_state 'console'.filter = 'x'
    T.ok(status_bar():find(' hide all scroll 3 filter "x" ' .. sep, 1, true), 'in order, together')

    control.view_state 'console'.hscroll = 16
    T.ok(status_bar():find(' scroll 3,+16 ', 1, true), 'horizontal scroll')
end)

T.case('[ui] theme and separators choose the status bar band and glyphs', function()
    boot()
    local control = T.require 'hub.ui.control'
    local powerline = utf8.char(0xE0B0)
    control.set_view 'console'
    HUB.state.config.ui = {}

    local bar = status_bar()
    T.eq(utf8.len(bar), tty_width, 'the band runs to the end of the row')
    T.ok(bar:find(powerline, 1, true), 'triangles by default')

    HUB.state.config.ui = {theme = 'classic', separators = 'plain'}
    bar = status_bar()
    T.ok(utf8.len(bar) < tty_width and not bar:find ' $', 'classic: no band')
    T.ok(not bar:find(powerline, 1, true), 'plain: no font glyphs')
    T.eq(T.require 'hub.ui.statusbar'.thin_separator, '│', 'plain: a bar between fragments of one background')
end)

T.case('chips and segments: padded when modern, capped when rounded, bracketed when classic', function()
    boot()
    local clicks = T.require 'hub.ui.clicks'
    local cap_l, cap_r = utf8.char(0xE0B6), utf8.char(0xE0B4)
    local hits = {}
    local function drawn(ui, f)
        HUB.state.config.ui = ui
        local win = ncurses.newwin(1, 40)
        clicks.reset()
        f(win)
        clicks.place(0, 1, 0)
        return V.fake_ncurses.row(win, 0)
    end
    local function chip(win) clicks.chip(win, 'x', function() end) end
    T.eq(drawn({}, chip), ' x ', 'modern: padded')
    T.eq(drawn({separators = 'rounded'}, chip), cap_l .. 'x' .. cap_r, 'rounded: between caps')
    T.eq(drawn({theme = 'classic'}, chip), '[x]', 'classic: in brackets')

    local function segments(win)
        clicks.segments(win, {
            {label = 'a', action = function() table.insert(hits, 'a') end},
            {label = 'b', on = true, action = function() table.insert(hits, 'b') end},
        })
    end
    T.eq(drawn({}, segments), ' a  b ', 'modern: adjacent chips')
    clicks.hit(0, 4, false)
    T.eq(drawn({separators = 'rounded'}, segments), cap_l .. 'a  b' .. cap_r, 'rounded: caps at the ends')
    clicks.hit(0, 0, false)
    T.eq(drawn({theme = 'classic'}, segments), '[a|b]', 'classic: one bracketed control')
    clicks.hit(0, 3, false)
    clicks.hit(0, 0, false)
    T.eq(hits, {'b', 'a', 'b'}, 'each segment clicks as its own, its brackets not')

    local function pair(win)
        clicks.chip(win, 'x', function() end)
        clicks.chip_gap(win)
        clicks.chip(win, 'y', function() end)
    end
    T.eq(drawn({}, pair), ' x   y ', 'modern: a space between chips')
    T.eq(drawn({separators = 'rounded'}, pair), cap_l .. 'x' .. cap_r .. cap_l .. 'y' .. cap_r,
        'rounded: the caps part them')
    T.eq(drawn({theme = 'classic', separators = 'rounded'}, pair), '[x] [y]', 'classic: a space, rounded or not')
end)

T.case('IRC colors on a band of color keep the band, and stay readable on it', function()
    boot()
    local draw = T.require 'hub.ui.draw'
    local addircstr = T.require 'hub.ui.irc_formatting'
    local colors = T.require 'hub.ui.colors'
    local set = {}
    rawset(ncurses, 'colorset', function(fore, back) table.insert(set, fore .. ',' .. back) end)
    local win = ncurses.newwin(1, 40)
    -- a band in the very color IRC 91 comes out as
    local band = colors.irc(91, ncurses.COLORS)
    draw.set_base(win, 200, band)
    addircstr(win, '\x0391hidden\x0304,99reset')
    rawset(ncurses, 'colorset', nil)
    local seen = {}
    for _, pair in ipairs(set) do seen[pair] = true end
    T.ok(seen['200,' .. band] and not seen[band .. ',' .. band], 'the band\'s color drawn in its text color')
    T.ok(seen[colors.irc(4, ncurses.COLORS) .. ',' .. band], 'a default background (99) is the band')
end)

T.case('the status bar names a few buffers with unseen messages, mentions first', function()
    local c = boot()
    local chat = T.require 'hub.features.chat'
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, chan in ipairs {'#a', '#b', '#c', '#d', '#e', '#f'} do
        c:recv(':me!u@h JOIN ' .. chan)
        chat.look(chat.buffer('test', chan))
    end
    cmdline.execute 'talk #a'
    control.set_view 'buffer'
    for _, chan in ipairs {'#b', '#c', '#d', '#e', '#f'} do
        c:recv(':bob!b@h PRIVMSG ' .. chan .. ' :hello')
    end
    c:recv ':carol!c@h PRIVMSG me :psst'

    local bar = status_bar()
    T.ok(bar:find(' carol .- #b .- #c .- #d .- %+2 *$'),
        'the mention, then by name, then how many more')
    T.ok(not bar:find('#e', 1, true) and not bar:find('#f', 1, true), 'the rest only counted')
end)

T.case('a list wraps under its value column, even when a word ends at the edge', function()
    boot()
    local fields = T.require 'hub.ui.fields'
    -- 32 columns: the label takes 12, so four words and their spaces end
    -- in the last column, which moves the cursor to the next row
    local win = ncurses.newpad(10, 32)
    local ctx = {cols = 32, vs = {expanded = {w = true}}, add_chip = function(w, text) w:waddstr('[', text, ']') end}
    fields.label(win, 'words')
    fields.words(ctx, win, 'w', {'aaaa', 'bbbb', 'cccc', 'dddd', 'eeee', 'ffff', 'gggg', 'hhhh'})
    T.eq(fake_ncurses.row(win, 0), '     words: aaaa bbbb cccc ', 'the fourth word goes to the next row')
    for y = 1, win.y - 1 do
        T.ok(fake_ncurses.row(win, y):find '^            %S', 'row ' .. y .. ' under the values')
    end
end)

T.case('wrapped text continues under its column, breaking a word too long for a row', function()
    boot()
    local draw = T.require 'hub.ui.draw'
    local addircstr = T.require 'hub.ui.irc_formatting'
    local win = ncurses.newpad(10, 20)
    win:waddstr 'label: '
    -- 19 columns a row: "label: aaaa bbbb " is 17, so cccc goes on
    draw.wrap_text(win, 'aaaa bbbb cccc dddddddddddddddddddd e', 20, 7)
    T.eq({fake_ncurses.row(win, 0), fake_ncurses.row(win, 1), fake_ncurses.row(win, 2), fake_ncurses.row(win, 3)},
        {'label: aaaa bbbb', '       cccc', '       dddddddddddd', '       dddddddd e'},
        'under the values, the long word broken')

    win = ncurses.newpad(10, 20)
    win:waddstr 'label: '
    addircstr(win, 'aaaa \x02bbbb\x02 cccc', nil, {cols = 20, indent = 7})
    T.eq({fake_ncurses.row(win, 0), fake_ncurses.row(win, 1)},
        {'label: aaaa bbbb', '       cccc'}, 'through the formatting')

    -- a code inside a word at the end of a row doesn't break it there
    win = ncurses.newpad(10, 20)
    win:waddstr 'label: '
    addircstr(win, 'aaaa bbbb cc\x02cc dd\x0304,05dd\x03 \x01', nil, {cols = 20, indent = 7})
    T.eq({fake_ncurses.row(win, 0), fake_ncurses.row(win, 1)},
        {'label: aaaa bbbb', '       cccc dddd ␁'}, 'the word moves whole, its codes taking no cells')

    -- ^D not followed by a color takes nothing, so ^C after it is a code
    -- and what follows is text
    win = ncurses.newpad(10, 20)
    win:waddstr 'label: '
    addircstr(win, 'aaaa \x04\x03abcdef gggggggg', nil, {cols = 20, indent = 7})
    T.eq({fake_ncurses.row(win, 0), fake_ncurses.row(win, 1)},
        {'label: aaaa abcdef', '       gggggggg'}, 'measured as drawn')
end)

T.case('a network that is down says why in /session and /networks', function()
    local c = boot()
    c:recv 'ERROR :Closing Link: 192.0.2.1 (Excess Flood)'
    c:finish 'end of stream'
    local control = T.require 'hub.ui.control'
    for _, view in ipairs {'session', 'networks'} do
        control.set_view(view)
        HUB.current.routes['ui.draw']()
        local text = table.concat(rows_of(document_pad()), '\n')
        T.ok(text:find('server: Closing Link: 192.0.2.1 (Excess Flood)', 1, true), view .. ' shows the reason')
        T.ok(not text:find('server server:', 1, true), view .. ' without its kind')
    end
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('a connecting network shows its step in /session and /networks', function()
    boot()
    local control = T.require 'hub.ui.control'
    HUB.state.nets.test.step = 'TLS with irc.example'
    for _, view in ipairs {'session', 'networks'} do
        control.set_view(view)
        HUB.current.routes['ui.draw']()
        local text = table.concat(rows_of(document_pad()), '\n')
        T.ok(text:find('TLS with irc.example', 1, true), view .. ' shows the step')
    end
end)

T.case("/session lists a bouncer's networks, with their state and errors", function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'session'
    local function text()
        HUB.current.routes['ui.draw']()
        return table.concat(rows_of(document_pad()), '\n')
    end
    T.ok(not text():find('Bouncer networks', 1, true), 'none without a bouncer')

    c:recv ':srv BATCH +b soju.im/bouncer-networks'
    c:recv '@batch=b :srv BOUNCER NETWORK 1 :name=libera;state=connected;host=irc.libera.chat;port=6697;tls=1;nickname=me;pass=secret'
    c:recv '@batch=b :srv BOUNCER NETWORK 2 :name=oftc;state=disconnected;realname=Me;error=Connection\\srefused'
    c:recv ':srv BATCH -b'
    local shown = text()
    T.ok(shown:find('Bouncer networks', 1, true), 'a section')
    T.ok(shown:find('1: libera  state connected  host irc.libera.chat:6697 tls  nick me', 1, true), 'a network')
    T.ok(shown:find('2: oftc  state disconnected  realname Me', 1, true), 'other attributes after')
    T.ok(shown:find('error: Connection refused', 1, true), 'its error under it')
    T.ok(not shown:find('secret', 1, true), 'never the password')
    T.eq(T.log_lines 'error', {}, 'no errors')
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
        local ctx = {cols = cols, vs = {expanded = {t = true}}, add_chip = function(w, text) w:waddstr('[', text, ']') end}
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

T.case('a private message shown in a channel is marked > after its sender, ours < after its recipient', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    c:recv ':me!u@h JOIN #chan'
    c:recv '@+draft/channel-context=#chan :alice!a@h PRIVMSG me :psst'
    c:recv '@+draft/channel-context=#chan :me!u@h PRIVMSG bob :back'
    talk.set_target('test', '#chan')
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    local rows = {}
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.h == tty_height - 1 and win.w ~= tty_width then
            for y = 0, win.h - 1 do table.insert(rows, fake_ncurses.row(win, y)) end
            break
        end
    end
    local text = table.concat(rows, '\n')
    T.ok(text:find('alice>psst', 1, true), 'theirs: ' .. text)
    T.ok(text:find('bob<back', 1, true), 'ours: ' .. text)
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

-- The rows of the main pad: as tall as the screen less the input line
local function main_rows()
    HUB.current.routes['ui.draw']()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.h == tty_height - 1 and win.w ~= tty_width then
            local rows = {}
            for y = 0, win.h - 1 do rows[y] = fake_ncurses.row(win, y) end
            return rows
        end
    end
    error 'no main pad'
end

local function on_main(text)
    for _, row in pairs(main_rows()) do
        if row:find(text, 1, true) then return true end
    end
    return false
end

T.case('hide rules leave messages out of the buffer view until Meta-H shows them there', function()
    local c = boot({}, {
        {buffer = '#audit', nick = 'OperServ', pattern = '^KLINE:EXPIRE:'},
        {buffer = '#small', command = 'JOIN', action = 'show'},
    })
    local chat = T.require 'hub.features.chat'
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    c:recv ':me!u@h JOIN #audit'
    c:recv ':me!u@h JOIN #small'
    c:recv ':OperServ!s@services PRIVMSG #audit :KLINE:EXPIRE: \x02*@192.0.2.1\x02'
    c:recv ':operserv!s@services PRIVMSG #audit :\x0304KLINE:EXPIRE:\x03 *@192.0.2.2'
    c:recv ':OperServ!s@services PRIVMSG #audit :KLINE:ADD: *@192.0.2.3'
    c:recv ':alice!a@h JOIN #audit'
    c:recv ':alice!a@h JOIN #small'
    T.eq(chat.buffer('test', '#audit').activity, 1, 'only the shown message counts')

    talk.set_target('test', '#audit')
    control.set_view 'buffer'
    T.ok(on_main 'KLINE:ADD:', 'a message no rule hides')
    T.ok(not on_main '192.0.2.1', 'hidden, bold in the text')
    T.ok(not on_main '192.0.2.2', 'hidden, the nick in any case and the text colored')
    T.ok(not on_main 'alice', 'a join, by the built-in rule')
    T.ok(on_main 'join', 'our own join is shown')
    T.ok(not status_bar():find('show', 1, true), 'no mode while hiding')

    key(-string.byte 'h')
    T.ok(on_main '192.0.2.1' and on_main 'alice', 'Meta-H shows them')
    T.ok(status_bar():find('show', 1, true), 'the mode reads show')

    -- each buffer keeps its own
    talk.set_target('test', '#small')
    T.ok(not status_bar():find('show', 1, true), 'another buffer hides')
    T.ok(on_main 'alice', "a show rule overrides the built-in one")
    talk.set_target('test', '#audit')
    T.ok(on_main '192.0.2.1', 'kept while switching')
    key(-string.byte 'h')
    T.ok(not on_main '192.0.2.1', 'hidden again')

    -- only what is shown moves the view's divider
    local buffer = chat.buffer('test', '#audit')
    main_rows()
    local ticker = buffer.messages.ticker
    c:recv ':bob!b@h JOIN #audit'
    c:recv ':OperServ!s@services PRIVMSG #audit :KLINE:EXPIRE: *@192.0.2.4'
    T.eq(buffer.messages.ticker, ticker, 'hidden messages leave it')
    c:recv ':bob!b@h PRIVMSG #audit :hello'
    T.eq(buffer.messages.ticker, ticker + 1, 'a shown one moves it')

    -- the detail pane names the rule
    local hidden
    for msg in T.require 'hub.lib.OrderedMap'.each(buffer.messages) do
        if (msg[2] or ''):find '192.0.2.1' then hidden = msg end
    end
    control.open_detail('message', 'test', hidden)
    HUB.current.routes['ui.draw']()
    T.ok(has_row(rows_of(detail_pad()), 'hidden in #audit by networks.test.hide.1'), 'the rule named')

    -- bringing a hidden message into view shows the buffer's hidden ones
    control.view_state 'buffer'.reveal = hidden
    main_rows()
    T.ok(on_main '192.0.2.1', 'revealed')
    T.ok(status_bar():find('show', 1, true), 'and showing')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('a click on a reply scrolls to the message it answers, until Esc', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    c:recv ':me!u@h JOIN #chan'
    c:recv '@msgid=parent :alice!a@h PRIVMSG #chan :the question'
    for i = 1, 60 do c:recv(':bob!b@h PRIVMSG #chan :filler ' .. i) end
    c:recv '@+reply=parent :carol!c@h PRIVMSG #chan :the answer'
    c:recv '@+reply=gone :carol!c@h PRIVMSG #chan :about something old'
    talk.set_target('test', '#chan')
    control.set_view 'buffer'
    local vs = control.view_state 'buffer'

    -- the main pad: as tall as the screen less the input line
    local function screen()
        HUB.current.routes['ui.draw']()
        for i = #fake_ncurses.windows, 1, -1 do
            local win = fake_ncurses.windows[i]
            if win.kind == 'newpad' and win.h == tty_height - 1 and win.w ~= tty_width then
                local rows = {}
                for y = 0, win.h - 1 do rows[y] = fake_ncurses.row(win, y) end
                return rows
            end
        end
    end
    local function click_reply(text)
        local rows = screen()
        for y = 0, #rows do
            local at = rows[y]:find(text, 1, true)
            if at then
                local arrow = rows[y]:find('↩', 1, true)
                HUB.current.routes['ui.entry']('on_mouse', y, utf8.len(rows[y]:sub(1, arrow - 1)), false)
                return
            end
        end
        error('not shown: ' .. text)
    end
    local function shown(text)
        for _, row in pairs(screen()) do
            if row:find(text, 1, true) then return true end
        end
        return false
    end

    T.ok(not shown 'the question', 'the parent is off the screen')
    vs.filter = 'answer'
    click_reply 'the answer'
    -- the scroll is worked out on the next frame
    screen()
    T.eq(vs.filter, nil, 'the filter is cleared')
    T.ok(vs.scroll > 0, 'scrolled')
    T.eq(vs.highlight and vs.highlight[2], 'the question', 'highlighted')
    T.ok(shown 'the question', 'the parent is on the screen')

    key(0x1b)
    T.eq({vs.scroll, vs.highlight}, {0}, 'Esc clears it')
    T.eq(T.log_lines 'error', {}, 'no errors')
    click_reply 'about something old'
    T.eq(T.log_lines 'error', {'the message replied to is not in this buffer'}, 'reported')
    T.eq(vs.scroll, 0, 'not scrolled')
end)

T.case('our messages show whether the server confirmed them', function()
    boot()
    local draw = T.require 'hub.ui.draw'
    local function shown(msg) return (draw.outbound(msg)) end
    T.eq({shown {}, shown {receipt = 'awaiting'}, shown {receipt = 'received'}},
        {'>>>', '>>>', '>>>'}, 'plain while awaiting and once received')
    T.eq({shown {receipt = 'rejected'}, shown {receipt = 'unknown'}},
        {'refused >>>', 'unconfirmed >>>'}, 'marked otherwise')
    T.eq(shown {delivery = {state = 'queued'}, receipt = 'awaiting'}, 'queued >>>', 'the queue comes first')
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
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'white normally')
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    T.eq(statusbar.title_color(), ncurses.COLOR_RED, 'red with a K-Line staged')
    oper.cancel 'test'
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'white once canceled')
    oper.stage_undline('test', '198.51.100.0/24')
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'only K-Lines')
end)

T.case('a ban staged from another view shows cliconn, where it is sent', function()
    boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    local oper = T.require 'hub.features.oper'
    control.set_view 'console'
    cmdline.execute 'kline *@192.0.2.0/24'
    T.eq(HUB.state.ui.view, 'cliconn', '/kline shows cliconn')

    control.set_view 'bans'
    oper.stage_undline('test', '198.51.100.0/24')
    T.eq(HUB.state.ui.view, 'bans', 'a view with the action bar stays')

    control.set_view 'console'
    cmdline.execute 'kline nick!u@h'
    T.eq(HUB.state.ui.view, 'console', 'nothing staged, nothing shown')
end)

T.case('Meta-H hides OFTC hybrid server notices in the console', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test', ircd = 'oftc-hybrid',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':a.example NOTICE me :Client connecting: n (~u@h.example) [192.0.2.1] {users} [Real Name]'
    c:recv ':bob!b@h PRIVMSG me :visible line'
    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    control.view_state('console').hide_snow = true
    HUB.current.routes['ui.draw']()
    local rows = {}
    for _, win in ipairs(fake_ncurses.windows) do
        for y = 0, win.h - 1 do table.insert(rows, fake_ncurses.row(win, y)) end
    end
    local text = table.concat(rows, '\n')
    T.ok(text:find('visible line', 1, true), 'other lines shown')
    T.ok(not text:find('Client connecting', 1, true), 'the notice hidden')
end)

T.case('/client counts the stores and what their entries hold', function()
    local c = boot()
    c:recv ':bob!b@h PRIVMSG me :hi'
    c:recv ':a.example NOTICE * :*** Notice -- op!o@staff.example{op} added global 60 min. K-Line for [*@192.0.2.9] [spam]'
    c:recv ':a.example NOTICE * :*** Notice -- Disconnecting K-Lined user n[~u@192.0.2.9] (*@192.0.2.9)'
    T.require 'hub.ui.control'.set_view 'client'
    HUB.current.routes['ui.draw']()
    local text = table.concat(rows_of(document_pad()), '\n', 0, document_pad().y)
    T.ok(text:find('ban nicks', 1, true), 'ban nicks counted')
    T.ok(text:find('awaiting replies', 1, true), 'chat replies counted')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('clicks follow a view scrolled sideways', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    -- a sender's button is columns 8-24, after the time
    control.view_state 'console'.hscroll = 10
    HUB.current.routes['ui.draw']()
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 5, false)
        if control.detail() then break end
    end
    T.eq(control.detail() and control.detail().kind, 'message', 'clicked where it is shown')
end)

-- The italic runs of a window's rows, trimmed, in order
local function italics_of(win)
    local runs = {}
    for y = 0, win.y do
        for _, run in ipairs(fake_ncurses.italics(win, y)) do
            run = run:match '^%s*(.-)%s*$'
            if run ~= '' then table.insert(runs, run) end
        end
    end
    return runs
end

T.case('nicks known to be away are in italics: members and a private target', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':srv CAP me ACK :away-notify'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 353 me = #chan :me alice bob'
    c:recv ':srv 301 me alice :lunch'
    c:recv ':carol!c@h JOIN #chan'
    c:recv ':carol!c@h AWAY :out'
    c:recv ':srv 306 me :You have been marked as being away'
    c:take()
    talk.set_target('test', '#chan')

    cmdline.execute 'chaninfo'
    c:take()
    HUB.current.routes['ui.draw']()
    T.eq(italics_of(detail_pad()), {'me', 'alice', 'carol', 'me'}, 'us, then the away members')

    talk.set_target('test', 'carol')
    control.set_view 'buffer'
    T.ok(status_bar():find('carol', 1, true), 'carol named')
    local bar
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newwin' and win.h == 1 and win.w == tty_width then bar = win break end
    end
    T.eq(italics_of(bar), {'carol'}, 'a private target')
    c:recv ':carol!c@h AWAY'
    status_bar()
    T.eq(italics_of(bar), {}, 'back')
end)

T.case('every built-in command has a group, and a usage when it takes arguments', function()
    boot()
    local problems = {}
    for name, cmd in pairs(HUB.current.commands) do
        if not cmd.group then table.insert(problems, name .. ': no group') end
        if cmd.spec ~= '' and not cmd.usage then table.insert(problems, name .. ': no usage') end
    end
    table.sort(problems)
    T.eq(problems, {}, 'complete')
end)

T.case('/help lists views as a row, then commands by group, and searches', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'help'
    local function text()
        HUB.current.routes['ui.draw']()
        return table.concat(rows_of(document_pad()), '\n', 0, document_pad().y)
    end

    local t = text()
    local headings = {}
    for line in t:gmatch '[^\n]+' do
        if line:match '^%u' and not line:match '^Commands' then table.insert(headings, line) end
    end
    T.eq(headings, {'Views', 'Client', 'Connection', 'Queries', 'Chat', 'Server notices', 'Operator',
        'Server admin', 'Topology', 'Services keys'}, 'groups in order')
    T.ok(t:find('/whowas nick [count]', 1, true), 'usage, not the parser spec')
    T.ok(not t:find('$g', 1, true), 'no specs')
    T.ok(t:find('/addwatch', 1, true) < t:find('/delwatch', 1, true)
        and t:find('/delwatch', 1, true) < t:find('/kline', 1, true), 'related commands together')

    -- a view's name shows it
    local rows = rows_of(document_pad())
    for y = 0, #rows do
        local x = rows[y]:find('/status', 1, true)
        if x and rows[y]:match '^  /' and not rows[y]:find 'Show' then
            HUB.current.routes['ui.entry']('on_mouse', y, x, false)
            break
        end
    end
    T.eq(HUB.state.ui.view, 'status', 'clicked')

    -- C-s searches names, usage and help
    control.set_view 'help'
    key(0x1f & string.byte 'S')
    type_text 'watch'
    t = text()
    T.ok(t:find('/addwatch', 1, true) and t:find('/delwatch', 1, true), 'matches')
    T.ok(not t:find('/oper', 1, true) and not t:find('Views', 1, true), 'nothing else')
    type_text 'zzz'
    T.ok(text():find('No command matches', 1, true), 'none')
    key(0x1b)
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('IRC and RGB colors become the nearest the terminal has', function()
    boot()
    local colors = T.require 'hub.ui.colors'
    local DIRECT = 1 << 24
    T.eq(colors.irc(99, 256), -1, '99 is the default')
    T.eq(colors.irc(4, 256), 9, 'red on the palette')
    T.eq(colors.irc(8, 16), 11, 'yellow, not white')
    T.eq(colors.irc(9, 8), 2, 'light green as green on 8 colors')
    T.eq(colors.irc(52, 256), 196, '16-98 by the xterm table')
    T.eq(colors.irc(52, 16), 9, '16-98 the nearest of 16')
    T.eq(colors.irc(52, 8), 1, '16-98 the nearest of 8')
    T.eq(colors.irc(52, DIRECT), 0xff0000, '16-98 as RGB')
    T.eq(colors.irc(2, DIRECT), 4, '0-7 of the palette with direct color')
    T.eq(colors.irc(12, DIRECT), 0x5c5cff, 'the bright half as RGB')
    T.eq(colors.rgb(0xff8700, 256), 208, 'the cube')
    T.eq(colors.rgb(0x808080, 256), 244, 'the gray ramp')
    T.eq(colors.rgb(0x0000ff, DIRECT), 0x0001ff, 'clear of palette indices')
end)

T.case('IRC formatting: colors, hex colors, and codes with nothing to draw', function()
    boot()
    local addircstr = T.require 'hub.ui.irc_formatting'
    local calls
    rawset(ncurses, 'colorset', function(fore, back) table.insert(calls, fore .. ',' .. back) end)
    local function drawn(str)
        calls = {}
        local win = ncurses.newwin(1, 80)
        addircstr(win, str)
        return fake_ncurses.row(win, 0), table.concat(calls, ' ')
    end
    local function eq(str, text, sets, what)
        local t, c = drawn(str)
        T.eq(t, text, what .. ': text')
        T.eq(c, sets, what .. ': colors')
    end
    eq('\x0304,12a\x0352b\x03c', 'abc', '9,12 196,12 -1,-1', 'the background stays until ^C')
    eq('\x0304,x', ',x', '9,-1', 'a comma with no color after it')
    eq('\x04FF8700a\x04ff0000,0000FFb', 'ab', '208,-1 196,21', 'hex colors')
    eq('\x04FFc', 'FFc', '-1,-1', 'a short hex color resets')
    eq('\x11m\x11\x1es\x1e', 'ms', '', 'monospace and strikethrough')
    eq('\x0303,03s', 's', '2,2', 'a spoiler stays hidden')
    rawset(ncurses, 'COLORS', 8)
    eq('\x0309,03x', 'x', '2,-1', 'colors that merge show on the default')
    rawset(ncurses, 'COLORS', nil)
    rawset(ncurses, 'colorset', nil)
end)

T.case('a forwarded JOIN shows the buffer forwarded to', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local talk = T.require 'hub.ui.talk'
    c:take()
    T.require 'hub.ui.cmdline'.execute 'talk #angularjs'
    T.eq(c:take(), {'JOIN #angularjs'}, 'joins')
    c:recv ':srv 470 me #angularjs #angular :Forwarding to another channel'
    c:recv ':me!u@h JOIN #angular'
    T.eq(talk.target 'test', '#angular', 'followed')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
    key(-string.byte 's')
    T.eq(talk.target 'test', '#angularjs', 'Meta-S goes back')
    HUB.current.routes['ui.draw']()
end)

T.case('connload colors versions from green, the newest, to red, the oldest', function()
    local c = boot()
    for _, server in ipairs {'a.example', 'b.example', 'c.example', 'd.example'} do
        c:recv(':' .. server .. ' NOTICE * :*** Notice -- Client connecting: n (~u@h.example) [198.18.0.1] {?} <*> [n]', false)
    end
    -- by number, 1.10 is newer than 1.9; d shares b's version
    c:recv ':a.example 351 me solanum-1.0(1.9) a.example :x'
    c:recv ':b.example 351 me solanum-1.0(1.10) b.example :x'
    c:recv ':c.example 351 me solanum-1.0(1.9.1) c.example :x'
    c:recv ':d.example 351 me solanum-1.0(1.10) d.example :x'
    -- services age apart from the ircd: alone, the newest of their kind
    c:recv(':services. NOTICE * :*** Notice -- Client connecting: n (~u@h.example) [198.18.0.1] {?} <*> [n]', false)
    c:recv ':services. 351 me atheme-7.3.0-rc2 services. :x'
    HUB.current.routes['app.tick']()

    local control = T.require 'hub.ui.control'
    control.set_view 'connload'
    control.view_state('connload').ordering = 'version'
    local calls = {}
    rawset(ncurses, 'colorset', function(fore) table.insert(calls, fore) end)
    HUB.current.routes['ui.draw']()
    rawset(ncurses, 'colorset', nil)
    local gradient = {}
    for _, fore in ipairs(calls) do
        if fore == 196 or fore == 226 or fore == 46 then table.insert(gradient, fore) end
    end
    T.eq(gradient, {196, 226, 46, 46, 46}, 'red, yellow, then green for both of the newest and services')
    T.eq(T.log_lines 'error', {}, 'no drawing errors')
end)

T.run()
