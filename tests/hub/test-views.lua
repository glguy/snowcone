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
    key(string.byte 't')
    key(-ncurses.KEY_UP)
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'hi there', 'chat goes into history')
    key(0x1b)

    -- action mode sends an action to the shown buffer
    key(string.byte 'a')
    T.eq(HUB.state.ui.input.mode, 'action', 'action mode')
    type_text 'waves'
    key(13)
    sent = c:take()
    T.eq(sent[#sent], 'PRIVMSG #chan :\x01ACTION waves\x01', 'sent as an action')
    T.eq(HUB.state.ui.input.mode, nil, 'one line, then back')
    key(string.byte 't')
    control.view_state 'buffer'.filter = 'kept'
    key(0x1f & string.byte 'G')
    T.eq(HUB.state.ui.input.mode, nil, 'C-g leaves input mode')
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), '', 'and drops the line')
    T.eq(control.view_state 'buffer'.filter, 'kept', 'but not the filter')
    control.view_state 'buffer'.filter = nil

    -- tab completes nicks in the channel
    c:recv ':srv 353 me = #chan :@me +alice'
    key(string.byte 't')
    type_text 'ali'
    key(9)
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'alice', 'completed')
    key(0x1b)
    T.eq(HUB.state.ui.input.mode, nil, 'Esc leaves input mode')

    -- Shift-Tab completes from the last candidate
    c:recv ':srv 353 me = #chan :alfred'
    key(string.byte 't')
    type_text 'al'
    key(-ncurses.KEY_BTAB)
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'alice', 'last of alfred, alice')
    key(-ncurses.KEY_BTAB)
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'alfred', 'then backward')

    -- Meta-Del kills a word, C-d deletes forward
    type_text ' and bob'
    key(-0x7f)
    key(0x1f & string.byte 'A')
    key(0x1f & string.byte 'D')
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'lfred and ', 'edited')
    key(0x1f) -- C-_
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'alfred and ', 'C-_ undoes')
    key(0x1b)

    -- Meta-A jumps to a buffer with activity
    c:recv ':bob!b@h PRIVMSG me :ping'
    control.set_view 'console'
    key(-string.byte 'a')
    T.eq({HUB.state.ui.view, control.talk_target 'test'}, {'buffer', 'bob'}, 'jumped')

    -- n steps through buffers in the buffer view, and C-n still steps views
    key(string.byte 'n')
    T.eq(control.talk_target 'test', '#chan', 'next buffer')
    key(string.byte 'p')
    T.eq(control.talk_target 'test', 'bob', 'previous buffer')
    key(0x1f & string.byte 'N')
    T.ok(HUB.state.ui.view ~= 'buffer', 'C-n leaves the buffer view')
    control.set_view 'buffer'

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

T.case('views follow their events once, after a reload too', function()
    local c = boot()
    T.ok(T.reload(), 'reloaded')
    local bus = T.require 'hub.runtime.bus'
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    for _, topic in ipairs {'chat.focus', 'chat.buffer', 'chat.show_list'} do
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
    T.eq({HUB.state.ui.view, control.talk_target 'test'}, {'buffer', '#a'}, '/talk shows the buffer')
    bus.emit('chat.show_list', {net = 'test'})
    T.eq(HUB.state.ui.view, 'list', 'the list')
    cmdline.execute 'close'
    T.eq(control.talk_target 'test', '#b', 'closing the shown buffer moves on')
end)

T.case('C-s leaves a prompt in place', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667, password = {prompt = 'server password'}},
        identity = {nick = 'me'},
    }}}}
    fake.last():con()
    local control = T.require 'hub.ui.control'
    local input = HUB.state.ui.input
    T.eq(input.mode, 'password', 'prompting')
    type_text 'hunter'
    key(0x1f & string.byte 'S')
    T.eq(input.mode, 'password', 'still prompting')
    T.eq(T.require 'hub.ui.editor'.content(control.editor()), 'hunter', 'answer kept')
    key(0x1f & string.byte 'G')
    T.eq(input.mode, nil, 'C-g aborts it')
    T.eq(input.prompts, {}, 'queue empty')
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
-- (the detail pane's is made before it)
local function document_pad()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.w == tty_width then return win end
    end
end

-- The detail pane's pad, which a wide kind makes wider than the screen:
-- the layout makes it just before the document pad, and the input line's
-- one-row pad after
local function detail_pad()
    local pads = {}
    for _, win in ipairs(fake_ncurses.windows) do
        if win.kind == 'newpad' and win.h > 1 then table.insert(pads, win) end
    end
    return pads[#pads - 1]
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

T.case('the status bar names the two who last started typing', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    clock.now = function() return now end
    c:recv ':me!u@h JOIN #chan'
    control.set_talk_target('test', '#chan')
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

T.case('a list wraps under its value column, even when a word ends at the edge', function()
    boot()
    local fields = T.require 'hub.ui.fields'
    -- 32 columns: the label takes 12, so four words and their spaces end
    -- in the last column, which moves the cursor to the next row
    local win = ncurses.newpad(10, 32)
    local ctx = {cols = 32, vs = {expanded = {w = true}}, add_button = function(w, text) w:waddstr(text) end}
    fields.label(win, 'words')
    fields.words(ctx, win, 'w', {'aaaa', 'bbbb', 'cccc', 'dddd', 'eeee', 'ffff', 'gggg', 'hhhh'})
    T.eq(fake_ncurses.row(win, 0), '     words: aaaa bbbb cccc ', 'the fourth word goes to the next row')
    for y = 1, win.y - 1 do
        T.ok(fake_ncurses.row(win, y):find '^            %S', 'row ' .. y .. ' under the values')
    end
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

T.case('a click on a reply scrolls to the message it answers, until Esc', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    c:recv '@msgid=parent :alice!a@h PRIVMSG #chan :the question'
    for i = 1, 60 do c:recv(':bob!b@h PRIVMSG #chan :filler ' .. i) end
    c:recv '@+reply=parent :carol!c@h PRIVMSG #chan :the answer'
    c:recv '@+reply=gone :carol!c@h PRIVMSG #chan :about something old'
    control.set_talk_target('test', '#chan')
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
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'white normally')
    oper.prepare_kline('test', 'n', '~u', 'h.example', '192.0.2.9')
    T.eq(statusbar.title_color(), ncurses.COLOR_RED, 'red with a K-Line staged')
    oper.cancel 'test'
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'white once canceled')
    oper.stage_undline('test', '198.51.100.0/24')
    T.eq(statusbar.title_color(), ncurses.COLOR_WHITE, 'only K-Lines')
end)

T.case('the message detail decodes server notices', function()
    local c = boot()
    local line = ':gold.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [Real]'
    c:recv(line)
    local msg = T.require 'hub.lib.OrderedMap'.lookup(HUB.state.nets.test.console, true)
    local message = T.require 'hub.ui.details.message'
    local note = message.decode(msg)
    T.eq({note.name, note.nick, note.ip, note.server}, {'connect', 'n', '192.0.2.1', 'gold.example'}, 'decoded')
    T.eq(message.decode(snowcone.parse_irc ':srv 001 me :Welcome'), nil, 'not a notice')

    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    control.open_detail('message', 'test', msg)
    HUB.current.routes['ui.draw']()
    key(-string.byte 'r')
    T.eq(control.detail().show_raw, true, 'Meta-R goes to the detail')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('the detail pane sits above the view, scrolls, and closes', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'status'
    HUB.current.routes['ui.draw']()

    -- a message with more rows than half the screen
    local tags = {}
    for i = 1, 40 do tags['t' .. i] = 'v' end
    local msg = snowcone.parse_irc ':a!b@c PRIVMSG #chan :hi'
    msg.tags = tags
    control.open_detail('message', 'test', msg)
    HUB.current.routes['ui.draw']()
    local detail = control.detail()
    T.eq(detail.max_scroll > 0, true, 'longer than the pane')
    -- 40 rows: 39 above the status bar, half of them for the pane
    -- with its rule, and a page keeps one row in view
    T.eq(detail.page, 17, 'a page of the pane')

    -- the paging keys scroll the pane, not the view
    key(-ncurses.KEY_NPAGE)
    T.eq(detail.scroll, 17, 'paged down')
    T.eq(control.view_state 'status'.scroll, 0, 'the view stays')
    key(-ncurses.KEY_UP)
    T.eq(detail.scroll, 16, 'a line up')

    -- the rule's [CLOSE] is clickable on the row below the pane
    local entry = HUB.current.routes['ui.entry']
    entry('on_mouse', 18, 2, false)
    T.eq(control.detail(), nil, 'closed by click')

    -- Esc closes the pane before it resets the view
    control.open_detail('message', 'test', msg)
    control.view_state 'status'.filter = 'kept'
    key(0x1b)
    T.eq(control.detail(), nil, 'closed by Esc')
    T.eq(control.view_state 'status'.filter, 'kept', 'the view is untouched')
    key(0x1b)
    T.eq(control.view_state 'status'.filter, nil, 'the next Esc resets the view')

    -- an unknown kind, as after a reload that removed it, is dropped
    control.open_detail('nonesuch', nil, {})
    HUB.current.routes['ui.draw']()
    T.eq(control.detail(), nil, 'dropped')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('clicking a buffer sender inspects the message in place', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':alice!a@h PRIVMSG #chan :hello'
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    local inspected = {}
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 15, false)
        local detail = control.detail()
        if detail then
            table.insert(inspected, detail.data.command .. ' ' .. table.concat(detail.data, ' '))
            control.close_detail()
        end
    end
    T.eq(inspected, {'JOIN #chan', 'PRIVMSG #chan hello'}, 'each sender opens its message')
    T.eq(HUB.state.ui.view, 'buffer', 'still in the buffer')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('a WHOWAS opens in the detail pane', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:take()
    cmdline.execute 'whowas old'
    T.eq(c:take(), {'WHOWAS old'}, 'sent')
    c:recv ':srv 314 me old u1 h1.example * :First'
    c:recv ':srv 312 me old srv.example :Fri Oct 30 10:00:00 2026'
    c:recv ':srv 314 me old u2 h2.example * :Second'
    c:recv ':srv 369 me old :End of WHOWAS'
    local detail = control.detail()
    T.eq({detail.kind, detail.net, #detail.data.entries}, {'whowas', 'test', 2}, 'shown')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('a WHOIS opens in the detail pane, and from its status line', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:take()
    cmdline.execute 'whois alice'
    T.eq(c:take(), {'WHOIS alice'}, 'sent')
    c:recv ':srv 311 me alice a h.example * :Alice A'
    c:recv ':srv 319 me alice :@#ops +#chan #lobby'
    c:recv ':srv 312 me alice srv.example :A server'
    c:recv ':srv 330 me alice acct :is logged in as'
    c:recv ':srv 317 me alice 75 1700000000 :seconds idle, signon time'
    c:recv ':srv 318 me alice :End of /WHOIS list.'

    T.eq(T.log_lines 'whois', {'alice!a@h.example account acct, 3 channels'}, 'one line')
    local detail = control.detail()
    T.eq({detail.kind, detail.net, detail.data.server, detail.data.idle}, {'whois', 'test', 'srv.example', 75}, 'shown')
    T.eq(detail.data.channels, {'@#ops', '+#chan', '#lobby'}, 'channels')
    HUB.current.routes['ui.draw']()

    -- the status line opens it again
    control.close_detail()
    control.set_view 'status'
    HUB.current.routes['ui.draw']()
    local opened
    for y = 0, tty_height - 1 do
        HUB.current.routes['ui.entry']('on_mouse', y, 40, false)
        if control.detail() then opened = true break end
    end
    T.ok(opened, 'clicked open')
    T.eq(control.detail().data.nick, 'alice', 'the same whois')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case("a query's nick in the status bar opens its WHOIS", function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:take()
    control.set_talk_target('test', 'alice')
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    for x = 0, tty_width - 1 do
        HUB.current.routes['ui.entry']('on_mouse', tty_height - 1, x, false)
        if #c.sent > 0 then break end
    end
    T.eq(c:take(), {'WHOIS alice'}, 'sent')
    c:recv ':srv 311 me alice a h.example * :Alice A'
    c:recv ':srv 318 me alice :End of /WHOIS list.'
    local detail = control.detail()
    T.eq({detail and detail.kind, detail and detail.data.nick}, {'whois', 'alice'}, 'shown')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('each event a detail kind names opens it, once, after a reload too', function()
    boot()
    T.ok(T.reload(), 'reloaded')
    local bus = T.require 'hub.runtime.bus'
    local control = T.require 'hub.ui.control'
    local reply, whois, whowas, value = {}, {}, {}, {}
    for _, case in ipairs {
        {'quote.sent', {net = 'test', reply = reply}, 'reply', 'test', reply},
        {'chat.whois', {net = 'test', whois = whois}, 'whois', 'test', whois},
        {'chat.whowas', {net = 'test', whowas = whowas}, 'whowas', 'test', whowas},
        {'eval.result', {value = value}, 'value', nil, value},
    } do
        local topic, ev, kind, net, data = case[1], case[2], case[3], case[4], case[5]
        local opened = 0
        for _, s in ipairs(HUB.current.bus.topics[topic]) do
            if s.owner == 'hub.ui' then opened = opened + 1 end
        end
        T.eq(opened, 1, topic .. ': one subscription')
        control.close_detail()
        bus.emit(topic, ev)
        local detail = control.detail()
        T.ok(detail and detail.kind == kind and detail.net == net and detail.data == data, topic)
    end
    control.close_detail()
    bus.emit('chat.show_channel', {net = 'test', target = '#chan'})
    local detail = control.detail()
    T.eq({detail.kind, detail.net, detail.data}, {'channel', 'test', {name = '#chan'}}, 'chat.show_channel')
end)

T.case('an error from code logs one line that opens its traceback', function()
    boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    HUB.boot.strict = false
    cmdline.execute 'eval error({}, 1)' -- caught by eval: not an error
    T.eq(T.log_lines 'error', {}, 'eval reports its own')

    -- a usage error is one line, with nothing more to show
    cmdline.execute 'quote'
    T.eq(T.tracebacks(), {}, 'no traceback')

    -- a bug in a command: one line, the traceback in its detail
    HUB.current.commands.boom = {name = 'boom', spec = '', help = '', pattern = function() return true end,
        fn = function() error 'kaboom' end}
    cmdline.execute 'boom'
    local errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('^boom: .*kaboom$'), errors[#errors])
    T.eq(T.log_lines 'trace', {}, 'no trace lines')
    T.eq(#T.tracebacks(), 1, 'the traceback is in the detail')
    T.ok(HUB.state.log_last:find('^boom: '), 'the status bar has the first line')
    T.eq(control.detail(), nil, 'not opened by itself')

    control.set_view 'status'
    HUB.current.routes['ui.draw']()
    for y = 0, tty_height - 1 do
        HUB.current.routes['ui.entry']('on_mouse', y, 40, false)
        if control.detail() then break end
    end
    local detail = control.detail()
    T.ok(detail, 'the status line opens it')
    T.eq({detail.kind, detail.data.where}, {'error', 'boom'}, 'the error')
    T.ok(detail.data.traceback:find('^stack traceback:'), 'with its traceback')
    T.ok(not detail.data.message:find '\n', 'the message without it')
    HUB.current.routes['ui.draw']()
end)

T.case('a new X25519 key shows its private key in the pane and nowhere else', function()
    boot()
    local control = T.require 'hub.ui.control'
    T.require 'hub.ui.cmdline'.execute 'x25519_new'
    local detail = control.detail()
    T.eq(detail.kind, 'keys', 'shown')
    local private = detail.data.private
    T.ok(private and #private > 0, 'with the private key')
    HUB.current.routes['ui.draw']()

    -- nothing in the log holds it, text or detail
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    for entry in OrderedMap.each(HUB.state.log) do
        T.ok(not entry.text:find(private, 1, true), 'not in a line')
        if entry.detail then
            for _, v in pairs(entry.detail.data) do
                T.ok(v ~= private, 'not in a detail')
            end
        end
    end

    -- a result of one line stays a log line
    control.close_detail()
    local dir = os.tmpname()
    T.require 'hub.ui.cmdline'.execute('cert_new ' .. dir)
    T.require 'hub.runtime.task'.answer(HUB.state.ui.input.prompts[1].task, '')
    T.require 'hub.ui.cmdline'.execute('cert_fp ' .. dir)
    os.remove(dir)
    T.eq(control.detail(), nil, 'no pane for a certificate')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('/eval shows its values in the detail pane, tables as a tree', function()
    boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'

    -- the detail pane's pad: made just before the document views' pad
    local function detail_rows()
        HUB.current.routes['ui.draw']()
        local rows = rows_of(detail_pad())
        return table.concat(rows, '\n', 0, #rows)
    end

    cmdline.execute "eval return 1, 'two', nil, {a = {b = 1}, [2] = true}"
    T.eq(T.log_lines 'eval', {'1, "two", nil, table (2 entries)'}, 'one summary line')
    local detail = control.detail()
    T.eq({detail.kind, detail.data.n}, {'value', 4}, 'shown, nil included')
    local text = detail_rows()
    T.ok(text:find('  2: "two"', 1, true), text)
    T.ok(text:find('  4: [-] table: ', 1, true), 'results start open')
    T.ok(text:find '     %[2%] = true\n     a = %[%+%] table: [^\n]* 1 entry', text)
    T.ok(not text:find('\n       b = 1', 1, true), 'not opened')

    -- the top result's toggle closes it, on the pane's rows
    HUB.current.routes['ui.entry']('on_mouse', 3, 6, false)
    T.ok(detail_rows():find('  4: [+] table: ', 1, true), 'closed by a click')

    -- a long table stops at 50 entries; a cycle doesn't recurse
    cmdline.execute 'eval local t = {} for i = 1, 60 do t[i] = i end t.self = t return t'
    detail = control.detail()
    text = detail_rows()
    T.ok(text:find('[+11 more]', 1, true), 'the rest behind a button')
    T.ok(not text:find 'self', 'string keys after numbers')
    detail.all['1'] = true
    T.ok(detail_rows():find('     self = cycle: table: ', 1, true), 'a cycle')

    -- an error stays one line, with no pane
    control.close_detail()
    cmdline.execute 'eval error "boom"'
    T.eq(control.detail(), nil, 'no pane for an error')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

-- Boot with labeled-response, which needs batch
local function boot_labeled()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :batch labeled-response message-tags'
    c:recv ':srv CAP me ACK :batch labeled-response message-tags'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c
end

-- The rows of the reply shown in the detail pane
local function reply_rows(control)
    local reply = control.detail().data
    local rows = {reply.state}
    for _, msg in ipairs(reply.messages) do
        table.insert(rows, tostring(msg.command) .. ' ' .. table.concat(msg, ' '))
    end
    return rows
end

T.case('a labeled /quote shows its reply batch in the detail pane', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_view 'status'

    cmdline.execute 'quote @+draft/x=1 LUSERS'
    T.eq(c:take(), {'@+draft/x=1;label=sc1 LUSERS'}, 'sent with its tags and a label')
    T.eq(control.detail().kind, 'reply', 'shown at once')
    T.eq(reply_rows(control), {'waiting'}, 'waiting')
    HUB.current.routes['ui.draw']()

    c:recv '@label=sc1 :srv BATCH +q labeled-response'
    c:recv '@batch=q :srv 251 me :There are 3 users'
    c:recv '@batch=q :srv 255 me :I have 3 clients'
    c:recv ':srv BATCH :-q'
    T.eq(reply_rows(control), {'done', '251 me There are 3 users', '255 me I have 3 clients'}, 'filled in')
    T.eq(T.log_lines 'quote', {'LUSERS: 2 replies'}, 'one line')
    HUB.current.routes['ui.draw']()

    -- a reply's command opens that message
    local opened
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 18, false)
        if control.detail().kind == 'message' then
            opened = control.detail().data
            break
        end
    end
    T.eq(opened and opened.command, 251, 'inspected')
    T.eq(next(HUB.tasks), nil, 'finished')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('a long reply draws the rows shown, all the way to its end', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_view 'status'

    -- more rows than a pad that holds everything may grow to
    cmdline.execute 'quote STATS i'
    c:take()
    c:recv('@label=sc1 :srv BATCH +s labeled-response', false)
    for i = 1, 5000 do
        c:recv(string.format('@batch=s :srv 215 me I * * u%d@h 0 c', i), false)
    end
    c:recv ':srv BATCH -s'
    local detail = control.detail()
    HUB.current.routes['ui.draw']()
    local pad = detail_pad()
    T.ok(pad.h < tty_height, 'a pad for the rows shown')
    T.eq(detail.max_scroll, 5001 - detail.page - 1, 'every message in reach')

    detail.scroll = detail.max_scroll
    HUB.current.routes['ui.draw']()
    local rows = rows_of(pad)
    T.ok(rows[detail.page]:find 'u5000@h', 'the last message on the last row')
    T.ok(rows[detail.page + 1]:find 'rows 4984%-5001 of 5001', 'the rule counts them')

    -- a click on the last row opens the message drawn there
    HUB.current.routes['ui.entry']('on_mouse', detail.page, 18, false)
    T.eq(control.detail().kind, 'message', 'inspected')
    T.eq(control.detail().data[5], 'u5000@h', 'the message on that row')

    -- a filter counts what it shows below the messages
    control.close_detail()
    control.open_detail('reply', 'test', detail.data)
    control.set_filter('detail', 'u4999@')
    HUB.current.routes['ui.draw']()
    rows = rows_of(pad)
    T.ok(rows[1]:find 'u4999@h', 'the match')
    T.eq(rows[2], '1 of 5000 messages match', 'counted')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('a labeled /quote takes a single reply, an ACK, or none', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'

    cmdline.execute 'quote TIME'
    T.eq(c:take(), {'@label=sc1 TIME'}, 'labeled')
    c:recv '@label=sc1 :srv 391 me srv :Friday'
    T.eq(reply_rows(control), {'done', '391 me srv Friday'}, 'one message')

    cmdline.execute 'quote MODE me +i'
    c:take()
    c:recv '@label=sc2 :srv ACK'
    T.eq(reply_rows(control), {'done', 'ACK '}, 'acknowledged')

    cmdline.execute 'quote PRIVMSG #chan :hi there'
    T.eq(c:take(), {'@label=sc3 PRIVMSG #chan :hi there'}, 'one label, not two')
    local t = select(2, next(HUB.tasks))
    HUB.current.routes['task.wake'](t.id, t.seq)
    T.eq(reply_rows(control), {'timeout'}, 'no reply')
    T.eq(T.log_lines 'quote', {'TIME: 1 reply', 'MODE me +i: acknowledged', 'PRIVMSG #chan :hi there: no reply'},
        'summaries')

    -- the status line opens a reply again
    control.close_detail()
    control.set_view 'status'
    HUB.current.routes['ui.draw']()
    for y = 0, tty_height - 1 do
        HUB.current.routes['ui.entry']('on_mouse', y, 40, false)
        if control.detail() then break end
    end
    T.eq(control.detail() and control.detail().kind, 'reply', 'reopened')
end)

T.case('/quote without labeled-response, or with a label typed, only sends', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    cmdline.execute 'quote @label=mine TIME'
    T.eq(c:take(), {'@label=mine TIME'}, 'the label as typed')
    T.eq(control.detail(), nil, 'nothing shown')

    local c2 = boot()
    c2:take()
    cmdline = T.require 'hub.ui.cmdline'
    control = T.require 'hub.ui.control'
    cmdline.execute 'quote TIME'
    T.eq(c2:take(), {'TIME'}, 'unlabeled')
    T.eq(control.detail(), nil, 'nothing shown')
    T.eq(next(HUB.tasks), nil, 'nothing waits')
end)

T.case('[DISCARD] drops a detail from the log lines that hold it', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local log = T.require 'hub.runtime.log'
    c:take()
    T.require 'hub.ui.cmdline'.execute 'whois alice'
    c:recv ':srv 311 me alice a h.example * :Alice'
    c:recv ':srv 318 me alice :End of /WHOIS list.'
    local data = control.detail().data
    T.ok(log.holds_detail(data), 'the log holds it')

    -- [DISCARD] follows [CLOSE] on the rule, the row below the pane
    HUB.current.routes['ui.draw']()
    local rule
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 10, false)
        if not control.detail() then rule = y break end
    end
    T.eq(control.detail(), nil, 'closed')
    T.ok(rule and rule > 0, 'from the rule')
    T.ok(not log.holds_detail(data), 'and dropped from the log')
    T.eq(T.log_lines 'whois', {'alice!a@h.example 0 channels'}, 'the line stays')

    -- a message, which no log line holds, has no [DISCARD]
    control.open_detail('message', 'test', snowcone.parse_irc ':a!b@c PRIVMSG #x :hi')
    HUB.current.routes['ui.draw']()
    HUB.current.routes['ui.entry']('on_mouse', rule, 10, false)
    T.ok(control.detail(), 'nothing there to click')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

-- The text of the detail pane as last drawn
local function detail_text()
    HUB.current.routes['ui.draw']()
    local pad = detail_pad()
    local rows = {}
    for y = 0, pad.y do table.insert(rows, fake_ncurses.row(pad, y)) end
    return table.concat(rows, '\n')
end

T.case('the filter searches a /quote reply live, and leaves the view alone', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_view 'status'
    control.view_state 'status'.filter = 'kept'

    cmdline.execute 'quote STATS o'
    c:take()
    c:recv '@label=sc1 :srv BATCH +q labeled-response'
    c:recv '@batch=q :srv 243 me O *@alpha.example * alice admin'
    c:recv '@batch=q :srv 243 me O *@beta.example * bob oper'
    c:recv '@batch=q :srv 243 me O *@gamma.example * carol admin'
    c:recv '@batch=q :srv 219 me o :End of /STATS report'
    c:recv ':srv BATCH :-q'
    T.ok(detail_text():find 'carol', 'every reply')

    -- Ctrl-S filters the pane as the pattern is typed
    key(0x1f & string.byte 'S')
    T.eq(HUB.state.ui.input.filter_target, 'detail', 'the pane takes the filter')
    type_text 'admin'
    local text = detail_text()
    T.ok(text:find 'alice' and text:find 'carol' and not text:find 'bob', 'live')
    T.ok(text:find '2 of 4 messages match', 'counted')
    T.ok(text:find 'filter "admin"', 'on the rule')

    -- Enter keeps it on the pane; the view's own is untouched
    key(13)
    T.eq(control.detail().filter, 'admin', 'saved on the detail')
    T.eq(control.view_state 'status'.filter, 'kept', 'not the view')
    T.ok(not detail_text():find 'bob', 'still filtered')

    -- Esc while filtering clears the pane's filter and keeps it open
    key(0x1f & string.byte 'S')
    type_text 'bob'
    key(0x1b)
    T.eq({control.detail().filter, HUB.state.ui.input.mode}, {nil, nil}, 'cleared')
    T.ok(detail_text():find 'bob', 'everything again')
    T.eq(control.view_state 'status'.filter, 'kept', 'the view keeps its own')

    -- /filter goes to the pane too
    cmdline.execute 'filter beta'
    T.eq(control.detail().filter, 'beta', '/filter')

    -- a kind that doesn't filter leaves the filter to the view
    control.open_detail('message', 'test', snowcone.parse_irc ':a!b@c PRIVMSG #x :hi')
    key(0x1f & string.byte 'S')
    T.eq(HUB.state.ui.input.filter_target, 'status', 'the view')
    type_text 'x'
    key(13)
    T.eq(control.view_state 'status'.filter, 'x', 'saved on the view')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('the filter shows the /whowas entries with a field that matches', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.open_detail('whowas', 'test', {nick = 'old', at = os.time(), entries = {
        {nick = 'old', user = 'u1', host = 'h1.example', server = 'alpha.example'},
        {nick = 'old', user = 'u2', host = 'h2.example', server = 'beta.example', account = 'acct'},
    }})
    control.set_filter('detail', 'acct')
    local text = detail_text()
    T.ok(text:find 'h2.example' and not text:find 'h1.example', 'the matching entry')
    T.ok(text:find '1 of 2 entries match', 'counted')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('Left and Right scroll a wide detail, and never the view under it', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_view 'console'
    local unit = tty_width - 26

    -- a kind that wraps has nothing to the side
    control.open_detail('message', 'test', snowcone.parse_irc ':a!b@c PRIVMSG #x :hi')
    key(-ncurses.KEY_RIGHT)
    T.eq({control.detail().hscroll, control.view_state 'console'.hscroll}, {0, 0}, 'neither moves')

    -- a reply's rows don't wrap, and scroll
    cmdline.execute 'quote INFO'
    c:take()
    c:recv('@label=sc1 :srv 371 me :' .. string.rep('x', 300) .. 'END')
    T.eq(control.detail().kind, 'reply', 'the reply')
    key(-ncurses.KEY_RIGHT)
    T.eq(control.detail().hscroll, unit, 'the pane moves')
    T.eq(control.view_state 'console'.hscroll, 0, 'the view does not')
    T.ok(detail_text():find('cols +' .. unit, 1, true), 'the rule says how far')
    key(-ncurses.KEY_LEFT)
    T.eq(control.detail().hscroll, 0, 'and back')

    -- closed, the keys are the view's again
    control.close_detail()
    key(-ncurses.KEY_RIGHT)
    T.eq(control.view_state 'console'.hscroll, unit, 'the view moves')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('clicks follow a view scrolled sideways', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    -- a command's button starts at column 26: time, then the source
    control.view_state 'console'.hscroll = 10
    HUB.current.routes['ui.draw']()
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 17, false)
        if control.detail() then break end
    end
    T.eq(control.detail() and control.detail().kind, 'message', 'clicked where it is shown')
end)

T.case('clicks follow a wide detail scrolled sideways, and its rule stays put', function()
    boot()
    local control = T.require 'hub.ui.control'
    T.require 'hub.ui.cmdline'.execute 'eval return {a = 1}'
    local detail = control.detail()
    T.eq(detail.kind, 'value', 'a wide kind')
    local function shown_open() return detail.open['1'] end

    -- the toggle of row 0 is at columns 5-7; scrolled 3 over, at 2-4
    detail.hscroll = 3
    HUB.current.routes['ui.draw']()
    T.ok(shown_open(), 'results start open')
    HUB.current.routes['ui.entry']('on_mouse', 0, 6, false)
    T.ok(shown_open(), 'not where it was drawn')
    HUB.current.routes['ui.entry']('on_mouse', 0, 3, false)
    T.ok(not shown_open(), 'where it is shown')

    -- the rule doesn't scroll sideways: [CLOSE] is still at column 1
    HUB.current.routes['ui.draw']()
    local rule
    for y = 1, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 1, false)
        if not control.detail() then rule = y break end
    end
    T.eq(rule, 1, 'closed from the rule under the one row')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('channel information: topic, modes, members and lists, live', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':srv 005 me CHANMODES=eIbq,k,flj,mnst PREFIX=(ov)@+ :are supported'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':srv 332 me #chan :the \x02topic'
    c:recv ':srv 333 me #chan alice!a@h 1700000000'
    c:recv ':srv 353 me = #chan :@me +bob alice carol'
    c:take()
    control.set_talk_target('test', '#chan')

    cmdline.execute 'chaninfo'
    T.eq(c:take(), {'MODE #chan'}, 'asks for the modes it lacks')
    T.eq({control.detail().kind, control.detail().data.name}, {'channel', '#chan'}, 'shown')
    local text = detail_text()
    T.ok(text:find 'topic: the topic', text)
    T.ok(text:find 'set by: alice  on ', 'who set it')
    T.ok(text:find 'modes: not known', 'modes not yet known')
    T.ok(text:find 'members: 4  @ 1  %+ 1', 'counted by rank')
    T.ok(text:find('nicks: @me +bob alice carol', 1, true), 'ranked, then by name')
    T.ok(text:find('bans: not fetched [↻]', 1, true), 'lists to fetch')

    -- replies fill it in as they come
    c:recv ':srv 324 me #chan +ntk sekrit'
    c:recv ':srv 329 me #chan 1600000000'
    c:recv ':carol!c@h TOPIC #chan :new topic'
    text = detail_text()
    T.ok(text:find('modes: k=sekrit n t', 1, true), text)
    T.ok(text:find 'created: ', 'created')
    T.ok(text:find 'topic: new topic' and text:find 'set by: carol', 'a new topic')

    -- [↻] asks for a list; its entries show newest first
    local fetched
    for y = 0, tty_height - 2 do
        for x = 0, 40 do
            HUB.current.routes['ui.entry']('on_mouse', y, x, false)
            local sent = c:take()
            -- past the modes' [↻], which asks for MODE again
            if sent[1] and sent[1]:find '+' then fetched = sent[1] break end
        end
        if fetched then break end
    end
    T.eq(fetched, 'MODE #chan +e', 'the first list, excepts')
    c:recv ':srv 367 me #chan *!*@old.example op!o@h 1600000000'
    c:recv ':srv 367 me #chan *!*@new.example op!o@h 1700000000'
    c:recv ':srv 368 me #chan :End of Channel Ban List'
    text = detail_text()
    T.ok(text:find('bans: 2 entries [+] [↻]', 1, true), text)
    T.ok(not text:find('new.example', 1, true), 'folded')

    -- [+] opens it, newest first; [-] folds it again
    local function click_text(label)
        local rows = {}
        for row in detail_text():gmatch '[^\n]*' do table.insert(rows, row) end
        for y, row in ipairs(rows) do
            local x = row:find(label, 1, true)
            if x and row:find 'bans:' then
                HUB.current.routes['ui.entry']('on_mouse', y - 1, x, false)
                return
            end
        end
        error('no ' .. label)
    end
    click_text '[+]'
    text = detail_text()
    T.ok(text:find('new.example', 1, true) < text:find('old.example', 1, true), 'newest first')
    T.ok(text:find('bans: 2 entries [-]', 1, true), 'open')

    -- [x] removes an entry; the server's MODE takes it off the list
    local y = 0
    for row in detail_text():gmatch '[^\n]*' do
        local x = row:find('[x] *!*@old.example', 1, true)
        if x then
            HUB.current.routes['ui.entry']('on_mouse', y, x, false)
            break
        end
        y = y + 1
    end
    T.eq(c:take(), {'MODE #chan -b *!*@old.example'}, 'removed by [x]')
    c:recv ':op!o@h MODE #chan -b *!*@old.example'
    T.ok(not detail_text():find('old.example', 1, true), 'gone from the list')
    c:recv ':op!o@h MODE #chan +b *!*@old.example'

    click_text '[-]'
    T.ok(not detail_text():find('new.example', 1, true), 'folded again')

    -- the filter shows matching members and entries, folded or not
    control.set_filter('detail', 'old')
    text = detail_text()
    T.ok(text:find 'bans: 1 of 2' and text:find 'old.example' and not text:find 'new.example', 'entries')
    T.ok(text:find 'matching: %-', 'no member matches')
    control.set_filter('detail', nil)

    -- the channel name in the status bar opens it too
    control.close_detail()
    control.set_view 'buffer'
    HUB.current.routes['ui.draw']()
    for x = 0, tty_width - 1 do
        HUB.current.routes['ui.entry']('on_mouse', tty_height - 1, x, false)
        if control.detail() then break end
    end
    T.eq(control.detail() and control.detail().kind, 'channel', 'from the status bar')

    -- not a channel
    cmdline.execute 'chaninfo bob'
    T.ok(T.log_lines 'error'[1]:find 'not a channel: bob', 'refused')
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
    T.eq(headings, {'Views', 'Client', 'Connection', 'Chat', 'Server notices', 'Operator', 'Topology',
        'Services keys'}, 'groups in order')
    T.ok(t:find('/whowas nick [count]', 1, true), 'usage, not the parser spec')
    T.ok(not t:find('$g', 1, true), 'no specs')
    T.ok(t:find('/addwatch', 1, true) < t:find('/delwatch', 1, true)
        and t:find('/delwatch', 1, true) < t:find('/oper', 1, true), 'related commands together')

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

T.run()
