-- The detail pane: what it shows of a message, a reply, a WHOIS or
-- WHOWAS, a channel, an error or a value, and how it scrolls and filters.
--
-- Run with:  snowcone tests/hub/test-details.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local V = dofile(here .. '/viewlib.lua')(T, here)
local FakeTransport, fake_ncurses, ncurses, boot = V.FakeTransport, V.fake_ncurses, V.ncurses, V.boot
local key, type_text, detail_pad, rows_of, has_row = V.key, V.type_text, V.detail_pad, V.rows_of, V.has_row
local detail_text = V.detail_text

T.case('the message detail shows its message in its buffer or the console', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local chat = T.require 'hub.features.chat'
    c:recv ':me!u@h JOIN #chan'
    c:recv '@msgid=target :alice!a@h PRIVMSG #chan :the target'
    for i = 1, 60 do c:recv(':bob!b@h PRIVMSG #chan :filler ' .. i) end
    c:recv ':carol!c@h PRIVMSG me :elsewhere'
    control.set_talk_target('test', 'carol')
    control.set_view 'channels'
    local msg = chat.find(chat.buffer('test', '#chan'), 'target')
    control.open_detail('message', 'test', msg)

    local entry = HUB.current.routes['ui.entry']
    local function click(button)
        HUB.current.routes['ui.draw']()
        local top = rows_of(detail_pad())[0]
        local at = top:find(button, 1, true)
        if not at then error('no button ' .. button .. ' in ' .. top) end
        -- a column past the button's first, counted in characters
        entry('on_mouse', 0, utf8.len(top, 1, at), false)
        -- the scroll is worked out on the next frame
        HUB.current.routes['ui.draw']()
    end

    local buffer_vs = control.view_state 'buffer'
    buffer_vs.filter = 'filler'
    click '→buffer'
    T.eq({HUB.state.ui.view, control.talk_target 'test'}, {'buffer', '#chan'}, 'shows its buffer')
    T.eq(buffer_vs.filter, nil, 'the filter is cleared')
    T.ok(buffer_vs.scroll > 0, 'scrolled')
    T.ok(buffer_vs.highlight == msg, 'highlighted')
    T.ok(control.detail().data == msg, 'still inspected')

    local console_vs = control.view_state 'console'
    console_vs.filter = 'carol'
    click '→console'
    T.eq(HUB.state.ui.view, 'console', 'shows the console')
    T.eq(console_vs.filter, nil, 'the console filter is cleared')
    T.ok(console_vs.scroll > 0, 'scrolled there too')

    -- a message in neither has neither button
    control.open_detail('message', 'test', snowcone.parse_irc ':a!b@c PRIVMSG #x :hi')
    HUB.current.routes['ui.draw']()
    T.eq(rows_of(detail_pad())[0]:match '^(.-)%s*$', '[summary|message|raw]', 'only the levels')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('the message detail reads OFTC hybrid replies and notices', function()
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
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local control = T.require 'hub.ui.control'
    local message = T.require 'hub.ui.details.message'
    control.set_view 'status'

    local function summary(line)
        c:recv(line)
        local log = HUB.state.nets.test.console
        local msg = OrderedMap.get(log, OrderedMap.last(log))
        control.open_detail('message', 'test', msg)
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad()), msg
    end
    local function expect(rows, wants)
        for _, want in ipairs(wants) do T.ok(has_row(rows, want), want) end
    end

    expect(summary ':srv 344 me #c *!*@loud.example op!o@h 1700000000', {
        '^   reply: RPL_QUIETLIST %(344%) to me, at ',
        '^ channel: #c$',
        '^    mask: %*!%*@loud.example$',
    })
    expect(summary ':srv 724 me *@192.0.2.0/24 3 4 :Local/remote clients match.', {
        '^   reply: RPL_TESTMASK %(724%) to me, at ',
        '^    mask: %*@192.0.2.0/24$',
        '^  remote: 4$',
    })
    expect(summary ':srv 480 me #c :You must connect via SSL to join this channel (+S)', {
        '^   error: ERR_SSLONLYCHAN %(480%) to me, at ',
    })
    local auth = summary ':srv 215 me I * * -&=~u@spoofed.example 0 users'
    expect(auth, {
        '^    auth: ~u@spoofed.example, class users, at ',
        '^   flags: no_tilde %(%-%), no_password %(&%), spoof %(=%)$',
    })
    for _, row in ipairs(auth) do
        T.ok(not row:find '^ *password:' and not row:find '^ *spoof:', 'no password or spoof name: ' .. row)
    end
    local rows, msg = summary ':srv 728 me victim :Is UnCaptured.'
    expect(rows, {'^   reply: RPL_ISUNCAPTURED %(728%) to me, at '})
    T.eq(message.color('test', msg.command), nil, 'not an error')

    local _, snote = summary ':a.example NOTICE me :Client connecting: n (~u@h.example) [192.0.2.1] {users} [Real]'
    local note = message.decode('test', snote)
    T.eq({note.name, note.nick, note.ip, note.server}, {'connect', 'n', '192.0.2.1', 'a.example'}, 'decoded')
    T.eq(message.snotice_text('test', snote), 'Client connecting: n (~u@h.example) [192.0.2.1] {users} [Real]', 'no header')

    -- recorded as it arrived: still a notice after our nick changes
    c:recv ':me!u@h NICK newme'
    T.eq(message.snotice_text('test', snote), 'Client connecting: n (~u@h.example) [192.0.2.1] {users} [Real]', 'kept')
    T.eq(message.decode('test', snote).nick, 'n', 'still decoded')
    local _, later = summary ':a.example NOTICE me :Client connecting: x (~u@h.example) [192.0.2.1] {users} [X]'
    T.eq(later.snote, false, 'to the old nick: not ours')
end)

T.case('the message detail decodes server notices', function()
    local c = boot()
    local line = ':gold.example NOTICE * :*** Notice -- Client connecting: n (u@h.example) [192.0.2.1] {users} <*> [Real]'
    c:recv(line)
    local msg = T.require 'hub.lib.OrderedMap'.lookup(HUB.state.nets.test.console, true)
    local message = T.require 'hub.ui.details.message'
    local note = message.decode('test', msg)
    T.eq({note.name, note.nick, note.ip, note.server}, {'connect', 'n', '192.0.2.1', 'gold.example'}, 'decoded')
    T.eq(message.decode('test', snowcone.parse_irc ':srv 001 me :Welcome'), nil, 'not a notice')

    local control = T.require 'hub.ui.control'
    control.set_view 'console'
    control.open_detail('message', 'test', msg)
    HUB.current.routes['ui.draw']()
    local detail = control.detail()
    T.eq(message.level(detail), 'summary', 'opens at the summary')
    local rows = rows_of(detail_pad())
    T.eq(rows[0]:match '^(.-)%s*$', '[summary|message|raw]  →console', 'the levels, and a jump to show it in the console')
    T.ok(has_row(rows, '^    sent: server notice, at '), 'a server notice')
    T.ok(has_row(rows, '^    name: connect$'), 'the parsed fields')
    T.ok(has_row(rows, '^    nick: n$'), 'in the summary column')

    -- the buttons are on the pane's top row
    local entry = HUB.current.routes['ui.entry']
    entry('on_mouse', 0, 12, false)
    T.eq(message.level(detail), 'message', 'the message level')
    HUB.current.routes['ui.draw']()
    T.ok(not has_row(rows_of(detail_pad()), 'name: connect'), 'without the parsed fields')
    entry('on_mouse', 0, 18, false)
    T.eq(message.level(detail), 'raw', 'the raw level')
    HUB.current.routes['ui.draw']()
    T.ok(has_row(rows_of(detail_pad()), '^         2: "%*%*%* Notice'), 'escaped')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('the message detail sums up a chat line', function()
    local c = boot()
    local irc = HUB.state.nets.test.irc --[[@as hub.Irc]]
    irc.caps_enabled['account-tag'] = true
    irc.caps_enabled['solanum.chat/identify-msg'] = true
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :me @alice bob'
    c:recv ':srv 366 me #c :End of /NAMES list.'
    c:recv('@account=work;solanum.chat/identified;bot;msgid=m1;solanum.chat/realhost=real.example'
        .. ' :alice!a@h.example PRIVMSG @#c :\x01ACTION waves\x01')
    c:recv ':bob!b@h PRIVMSG #c :plain'
    local chat = T.require 'hub.features.chat'
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local buffer = chat.buffer('test', '#c')
    local control = T.require 'hub.ui.control'
    local message = T.require 'hub.ui.details.message'

    control.set_view 'status'
    control.open_detail('message', 'test', OrderedMap.lookup(buffer.messages, 'm1'))
    HUB.current.routes['ui.draw']()
    local rows = rows_of(detail_pad())
    for _, want in ipairs {
        '^    from: alice a@h.example, real host real.example$',
        '^identity: account work, identified$',
        '^    role: @ %+o, bot$',
        '^    sent: action to #c, @ and above only, at %d%d:%d%d:%d%d$',
        '^    text: waves$',
    } do
        T.ok(has_row(rows, want), want)
    end
    T.ok(not has_row(rows, 'msgid'), 'without its other tags')

    control.open_detail('message', 'test', chat.newest(buffer))
    HUB.current.routes['ui.draw']()
    rows = rows_of(detail_pad())
    for _, want in ipairs {
        '^identity: not logged in, not identified$',
        '^    role: no channel modes$',
        '^    sent: message to #c, at ',
    } do
        T.ok(has_row(rows, want), want)
    end
    T.ok(not has_row(rows, 'bot'), 'a bot only says so')

    -- a command without a summary opens at the message level
    control.open_detail('message', 'test', snowcone.parse_irc ':alice!a@h AWAY :gone')
    HUB.current.routes['ui.draw']()
    T.eq(message.level(control.detail()), 'message', 'no summary')
    T.eq(rows_of(detail_pad())[0]:match '^(.-)%s*$', '[message|raw]', 'nor its segment')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('the message detail sums up a topic change with the topic it replaced', function()
    local c = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 332 me #c :the old topic'
    c:recv ':srv 333 me #c bob 1700000000'
    c:recv ':srv 353 me = #c :me @alice'
    c:recv ':srv 366 me #c :End of /NAMES list.'
    c:recv ':alice!a@h TOPIC #c :the \x02new\x02 topic'
    local chat = T.require 'hub.features.chat'
    local buffer = chat.buffer('test', '#c')
    local control = T.require 'hub.ui.control'
    local message = T.require 'hub.ui.details.message'

    control.set_view 'status'
    control.open_detail('message', 'test', chat.newest(buffer))
    HUB.current.routes['ui.draw']()
    T.eq(message.level(control.detail()), 'summary', 'opens at the summary')
    local rows = rows_of(detail_pad())
    local set = (os.date('%Y-%m-%d %H:%M', 1700000000) --[[@as string]]):gsub('%-', '%%-')
    for _, want in ipairs {
        '^    from: alice a@h$',
        '^    role: @ %+o$',
        '^ changed: topic of #c, at ',
        '^   topic: the new topic$',
        '^  before: the old topic$',
        '^ was set: by bob, ' .. set .. ', %d+d %d+h ago$',
    } do
        T.ok(has_row(rows, want), want)
    end

    c:recv ':bob!b@h TOPIC #c :'
    control.open_detail('message', 'test', chat.newest(buffer))
    HUB.current.routes['ui.draw']()
    rows = rows_of(detail_pad())
    T.ok(has_row(rows, '^   topic: cleared$'), 'cleared')
    T.ok(has_row(rows, '^  before: the new topic$'), 'the one alice set')
    T.ok(has_row(rows, '^ was set: by alice!a@h, '), 'by alice')

    -- a channel whose topic we never learned
    c:recv ':me!u@h JOIN #d'
    c:recv ':carol!c@h TOPIC #d :first'
    control.open_detail('message', 'test', chat.newest(chat.buffer('test', '#d')))
    HUB.current.routes['ui.draw']()
    rows = rows_of(detail_pad())
    T.ok(has_row(rows, '^  before: not known$'), 'not known')
    T.ok(not has_row(rows, 'was set'), 'nor who set it')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('the message detail sums up joins, parts, kicks, quits, nicks, modes and replies', function()
    local c = boot()
    c:recv ':srv 005 me PREFIX=(ov)@+ CHANMODES=eIbq,k,flj,imnpst :are supported'
    c:recv ':me!u@h JOIN #c'
    c:recv ':srv 353 me = #c :me @alice +bob carol'
    c:recv ':srv 366 me #c :End of /NAMES list.'
    local chat = T.require 'hub.features.chat'
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local control = T.require 'hub.ui.control'
    control.set_view 'status'

    -- the summary of the newest line in #c, or of the newest console line
    local function summary(line, console)
        c:recv(line)
        local msg
        if console then
            local log = HUB.state.nets.test.console
            msg = OrderedMap.get(log, OrderedMap.last(log))
        else
            msg = chat.newest(chat.buffer('test', '#c'))
        end
        control.open_detail('message', 'test', msg)
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad())
    end
    local function expect(rows, wants)
        for _, want in ipairs(wants) do T.ok(has_row(rows, want), want) end
    end

    expect(summary ':dave!d@h JOIN #c acct :Dave \x02D\x02', {
        '^    from: dave d@h$',
        '^  joined: #c, at ',
        '^realname: Dave D$',
    })
    expect(summary ':alice!a@h MODE #c +o-v+bl dave bob *!*@x.example 10', {
        '^    role: @ %+o$',
        '^ changed: modes of #c, at ',
        '^   modes: %+o dave op$',
        '^          %-v bob voice$',
        '^          %+b %*!%*@x.example ban$',
        '^          %+l 10 limit$',
    })
    expect(summary ':alice!a@h KICK #c carol :be nice', {
        '^  kicked: carol from #c, at ',
        '^  reason: be nice$',
    })
    expect(summary ':dave!d@h PART #c :later', {
        '^    role: @ %+o$',
        '^    left: #c, at ',
        '^  reason: later$',
    })
    expect(summary ':alice!a@h NICK alicia', {
        '^    from: alice a@h$',
        '^ renamed: to alicia, at ',
    })
    expect(summary ':alicia!a@h CHGHOST new new.example', {
        '^    from: alicia a@h$',
        '^    host: now new@new.example, at ',
    })
    expect(summary ':alicia!new@new.example ACCOUNT work', {
        '^ account: logged in as work, at ',
    })
    expect(summary ':alicia!new@new.example QUIT :hub.example leaf.example', {
        '^    quit: netsplit, at ',
        '^  reason: hub.example leaf.example$',
        '^    left: #c$',
    })
    expect(summary(':srv 401 me ghost :No such nick/channel', true), {
        '^    from: srv, server$',
        '^   error: ERR_NOSUCHNICK %(401%) to me, at ',
        '^    nick: ghost$',
        '^    text: No such nick/channel$',
    })
    local set = (os.date('%Y-%m-%d %H:%M', 1700000000) --[[@as string]]):gsub('%-', '%%-')
    expect(summary(':srv 367 me #c *!*@bad.example alice!a@h 1700000000', true), {
        '^   reply: RPL_BANLIST %(367%) to me, at ',
        '^ channel: #c$',
        '^    mask: %*!%*@bad.example$',
        '^      by: alice!a@h$',
        '^     set: ' .. set .. ', ',
    })
    expect(summary(':srv 728 me #c q *!*@loud.example', true), {
        '^   reply: RPL_QUIETLIST %(728%) to me, at ',
        '^    mask: %*!%*@loud.example$',
    })
    expect(summary(':srv 368 me #c :End of Channel Ban List', true), {
        '^ channel: #c$',
        '^    text: End of Channel Ban List$',
    })
    expect(summary(':srv 215 me I staff.example <NULL> %=^*@*.example 0 opers :Staff', true), {
        '^    auth: %*@%*.example, class opers, at ',
        '^   flags: need_sasl %(%%%), spoof %(=%), kline_exempt %(%^%)$',
        '^   spoof: staff.example$',
        '^    desc: Staff$',
    })
    local rows = summary(':srv 215 me I irc.other.example secret *@255.255.255.255 6697 users :', true)
    expect(rows, {
        '^    auth: %*@%(hidden%), class users, at ',
        '^redirect: irc.other.example port 6697$',
        '^password: secret$',
    })
    T.ok(not has_row(rows, 'flags') and not has_row(rows, 'desc'), 'no flags, no description')
    expect(summary(':srv 216 me k *.example * ~bad :Spam (2026/11/01)|ticket 42', true), {
        '^   reply: RPL_STATSKLINE %(216%) to me, at ',
        '^    type: temporary K%-Line$',
        '^    host: %*.example$',
        '^    user: ~bad$',
        '^  reason: Spam %(2026/11/01%)$',
        '^oper why: ticket 42$',
    })
    expect(summary(':srv 205 me User users alice[a@h.example] (192.0.2.7) 12 300', true), {
        '^   class: users$',
        '^  client: alice%[a@h.example%]$',
        '^      ip: 192.0.2.7$',
        '^   heard: 12s$',
        '^    idle: 5m$',
    })
    expect(summary(':srv 725 me K 0 *@bad.example :Spam', true), {
        '^    type: K%-Line$',
        '^    left: permanent$',
        '^    mask: %*@bad.example$',
    })
    expect(summary(':srv 324 me #c +ntk secret', true), {
        '^ channel: #c$',
        '^   modes: %+ntk secret$',
    })
    expect(summary(':srv 005 me CHANTYPES=# NICKLEN=16 :are supported by this server', true), {
        '^  tokens: CHANTYPES=# NICKLEN=16$',
        '^    text: are supported by this server$',
    })
    local message = T.require 'hub.ui.details.message'
    c:recv ':srv 999 me what :is this'
    local log = HUB.state.nets.test.console
    control.open_detail('message', 'test', OrderedMap.get(log, OrderedMap.last(log)))
    T.eq(message.level(control.detail()), 'message', 'a reply not known has no summary')
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
    local msg = snowcone.parse_irc ':a!b@c AWAY :gone'
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

    -- the wheel scrolls what it is over
    local entry = HUB.current.routes['ui.entry']
    entry('on_wheel', 3, 10, -1)
    T.eq(detail.scroll, 19, 'wheeled down over the pane')
    entry('on_wheel', 3, 10, 1)
    T.eq(detail.scroll, 16, 'wheeled up over the pane')
    entry('on_wheel', 25, 10, -1)
    T.eq(detail.scroll, 16, 'the view takes the wheel below the pane')

    -- the rule's [CLOSE] is clickable on the row below the pane
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

T.case('a WHO opens in the detail pane as a table', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':srv 005 me BOT=B WHOX :are supported'
    c:take()
    cmdline.execute 'who #chan %tcuinfdlar,7'
    T.eq(c:take(), {'WHO #chan %tcuinfdlar,7'}, 'sent')
    c:recv ':srv 354 me 7 #chan ~a 255.255.255.255 alice H@ 0 0 acct :Alice A'
    c:recv ':srv 354 me 7 #chan b 255.255.255.255 bob GB 1 300 0 :Bob'
    c:recv ':srv 315 me #chan :End of /WHO list.'
    local detail = control.detail()
    T.eq({detail.kind, detail.net, #detail.data.rows}, {'who', 'test', 2}, 'shown')
    local text = detail_text()
    T.ok(text:find('nick  status channel user ip hops idle account realname', 1, true), 'a header per field given')
    T.ok(text:find('alice H@     #chan   ~a   -  0    -    acct    Alice A', 1, true), 'none and 0 idle are -')
    T.ok(text:find('bob   GB     #chan   b    -  1    5m   -       Bob', 1, true), 'idle as a duration')
    T.ok(text:find('who #chan %tcuinfdlar,7 (2 users)', 1, true), 'the title')

    control.set_filter('detail', 'Bob')
    text = detail_text()
    T.ok(not text:find 'alice H@', 'filtered out')
    T.ok(text:find('1 of 2 users match', 1, true), 'counted')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('a STATS opens as tables by reply, read for what their fields mean, laid out once', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:take()
    cmdline.execute 'stats L'
    T.eq(c:take(), {'STATS L'}, 'sent')
    c:recv ':srv 216 me K bad.example * ~u :spam|by alice'
    c:recv ':srv 216 me K worse.example * * :flood'
    c:recv ':srv 211 me hub.example 0 10 2 12 3 :3600 30 TS QS'
    c:recv ':srv 249 me L :a line of text'
    c:recv ':srv 219 me L :End of /STATS report'
    local detail = control.detail()
    T.eq({detail.kind, #detail.data.messages}, {'listing', 4}, 'shown')

    local text = detail_text()
    T.ok(text:find('STATS L (4 replies)', 1, true), 'the title')
    T.ok(text:find('RPL_STATSKLINE 216  2', 1, true), 'a heading per reply, with its count')
    T.ok(text:find('type   host          user reason oper reason', 1, true), 'its fields, the reasons apart')
    T.ok(text:find('K-Line bad.example   ~u   spam   by alice', 1, true), 'the ban type by name')
    T.ok(text:find('K-Line worse.example *    flood  -', 1, true), 'no oper reason is -')
    T.ok(text:find('link        sendq sent msgs sent KiB recv msgs recv KiB open idle caps', 1, true),
        'a link')
    T.ok(text:find('hub.example 0     10        2        12        3        60m  30s  TS QS', 1, true),
        'its times read out')
    T.ok(text:find('a line of text', 1, true), 'text as text')

    -- laid out once, and again only for a new filter
    local view = detail.data.view
    local layout = view.sections[1].table.layout
    detail_text()
    T.ok(detail.data.view == view and view.sections[1].table.layout == layout, 'kept')

    control.set_filter('detail', 'worse')
    text = detail_text()
    T.ok(not text:find 'bad.example', 'filtered out')
    T.ok(not text:find 'RPL_STATSLINKINFO', 'with the tables that have no match')
    T.ok(text:find('1 of 4 replies match', 1, true), 'counted')
    T.ok(view.sections[1].table.layout == layout, 'the layout kept')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case('an auth block reads out its flags, and MASKTRACE names the server', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:take()
    cmdline.execute 'stats I'
    c:take()
    c:recv ':srv 215 me I spoofed.example <NULL> =%~u@*.example 0 users :Some block'
    c:recv ':srv 219 me I :End of /STATS report'
    local text = detail_text()
    T.ok(text:find('~u@*.example spoof,need_sasl users spoofed.example', 1, true), 'flags, in order, and spoof')
    T.ok(text:find('Some block', 1, true), 'the description')

    T.require 'hub.features.oper'
    local listing = T.require 'hub.features.listing'
    T.require 'hub.runtime.task'.spawn('masktrace', {net = 'test'}, listing.masktrace, '*@h.example')
    c:take()
    c:recv ':srv 709 me User leaf.example bob b h.example 192.0.2.2 :Bob'
    c:recv ':srv 709 me User leaf.example carol c h.example 0 :Carol'
    c:recv ':srv 262 me srv.example :End of TRACE'
    text = detail_text()
    T.ok(text:find('type server       nick  user host      ip        realname', 1, true), 'server, not class')
    T.ok(text:find('User leaf.example carol c    h.example -         Carol', 1, true), 'a hidden address is -')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case("OFTC hybrid's reasons have spaces about the |, and a reason may be the oper's alone", function()
    local c = boot(nil, nil, 'oftc-hybrid')
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:take()
    cmdline.execute 'stats k'
    c:take()
    c:recv ':srv 216 me K bad.example * ~u :spam | '
    c:recv ':srv 216 me K worse.example * * :|only opers'
    c:recv ':srv 219 me k :End of /STATS report'
    T.eq(control.detail().kind, 'listing', 'shown')
    local text = detail_text()
    T.ok(text:find('K-Line bad.example   ~u   spam   -', 1, true), 'no oper reason')
    T.ok(text:find('K-Line worse.example *    -      only opers', 1, true), 'only an oper reason')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case("a table's header stays at the top as its rows scroll under it", function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    c:recv ':srv 005 me WHOX :are supported'
    c:take()
    cmdline.execute 'who #chan %n'
    c:take()
    for i = 1, 100 do c:recv(string.format(':srv 354 me user%03d', i)) end
    c:recv ':srv 315 me #chan :End of /WHO list.'
    local detail = control.detail()
    local function screen()
        HUB.current.routes['ui.draw']()
        return rows_of(detail_pad())
    end

    T.eq(screen()[0]:match '^%S+', 'nick', 'the header, at the top')
    detail.scroll = 10
    local rows = screen()
    T.eq({rows[0]:match '^%S+', rows[1]:match '^%S+'}, {'nick', 'user010'}, 'pinned over the users scrolled')
    detail.scroll = 1e9
    rows = screen()
    local shown = {}
    for y = 0, #rows do
        local word = rows[y]:match '^(user%d+)'
        if word then table.insert(shown, word) end
    end
    T.eq({rows[0]:match '^%S+', shown[#shown]}, {'nick', 'user100'}, 'and the last user shows under it')

    -- a listing pins the header of the table at the top
    cmdline.execute 'trace'
    c:take()
    for i = 1, 60 do
        c:recv(string.format(':srv 205 me User users u%02d[u@192.0.2.1] (192.0.2.1) 9 60', i))
    end
    c:recv ':srv 209 me Class users 60'
    c:recv ':srv 262 me srv.example :End of TRACE'
    detail = control.detail()
    T.eq(detail.kind, 'listing', 'a listing')
    detail.scroll = 20
    rows = screen()
    T.eq({rows[0]:match '^%S+', rows[1]:match '^%S+'}, {'class', 'users'}, "the users' header")
    detail.scroll = 1e9
    rows = screen()
    T.ok(rows[0]:match '^class%s+client', "at the end, the users' header still pinned")
    T.ok(has_row(rows, '^class users$') and has_row(rows, '^users 60$'), 'over the classes, with their own')
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
    os.remove(dir) -- cert_new won't overwrite a file
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

    -- a reply's sender opens that message
    local opened
    for y = 0, tty_height - 2 do
        HUB.current.routes['ui.entry']('on_mouse', y, 5, false)
        if control.detail().kind == 'message' then
            opened = control.detail().data
            break
        end
    end
    T.eq(opened and opened.command, 251, 'inspected')
    T.eq(next(HUB.tasks), nil, 'finished')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.case("a /quote's reply shows as tables at [table|raw], and back again", function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_view 'status'

    cmdline.execute 'quote STATS k'
    c:take()
    T.ok(not detail_text():find('table', 1, true), 'no control while waiting')
    c:recv '@label=sc1 :srv BATCH +s labeled-response'
    c:recv '@batch=s :srv 216 me K bad.example * ~u :spam|by alice'
    c:recv '@batch=s :srv 219 me k :End of /STATS report'
    c:recv '@batch=s :srv NOTICE me :a notice'
    c:recv ':srv BATCH -s'

    local function click(button)
        HUB.current.routes['ui.draw']()
        local top = rows_of(detail_pad())[0]
        local at = top:find(button, 1, true)
        if not at then error('no button ' .. button .. ' in ' .. top) end
        HUB.current.routes['ui.entry']('on_mouse', 0, utf8.len(top, 1, at), false)
    end
    T.ok(detail_text():find('[table|raw] >>> STATS k', 1, true), 'both views, raw lit')
    click 'table'
    local text = detail_text()
    T.ok(text:find('[table|raw] >>> STATS k', 1, true), 'the line sent, and the way back')
    T.ok(text:find('type   host        user reason oper reason', 1, true), 'a table per reply, by its fields')
    T.ok(text:find('K-Line bad.example ~u   spam   by alice', 1, true), 'read as STATS reads it')
    T.ok(text:find('RPL_ENDOFSTATS 219', 1, true), 'the end, a table of its own')
    T.ok(text:find('NOTICE  1', 1, true) and text:find('me a notice', 1, true),
        'a command, its arguments as text')

    local reply = control.detail().data
    local view = reply.view
    detail_text()
    T.ok(reply.view == view, 'the tables kept on the reply')

    click 'raw'
    text = detail_text()
    T.ok(text:find('[table|raw] >>> STATS k', 1, true) and text:find('216 RPL_STATSKLINE K bad.example', 1, true),
        'raw again')
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

    -- a click on the last row's sender opens the message drawn there
    HUB.current.routes['ui.entry']('on_mouse', detail.page, 5, false)
    T.eq(control.detail().kind, 'message', 'inspected')
    T.eq(control.detail().data[5], 'u5000@h', 'the message on that row')

    -- ←BACK, on the rule beside [CLOSE], returns to the reply as it was
    HUB.current.routes['ui.draw']()
    local rule, back
    for y, row in pairs(rows_of(detail_pad())) do
        local at = row:find('←BACK', 1, true)
        if at then rule, back = y, utf8.len(row:sub(1, at - 1)) end
    end
    T.ok(rows_of(detail_pad())[rule]:find('[CLOSE]─←BACK', 1, true), 'beside [CLOSE]')
    HUB.current.routes['ui.entry']('on_mouse', rule, back + 1, false)
    T.ok(control.detail() == detail, 'back to the reply')
    T.eq(detail.scroll, detail.max_scroll, 'scrolled as it was')
    T.eq(control.can_go_back(), false, 'nothing further back')
    HUB.current.routes['ui.draw']()
    T.ok(not rows_of(pad)[detail.page + 1]:find('←BACK', 1, true), 'so no ←BACK')
    control.follow_detail('message', 'test', snowcone.parse_irc ':srv PING :x')
    control.open_detail('message', 'test', snowcone.parse_irc ':srv PING :y')
    T.eq(control.can_go_back(), false, 'opening from elsewhere starts afresh')

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

T.case('the modern theme draws the rule as a band: close and title left, DISCARD right', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local log = T.require 'hub.runtime.log'
    HUB.state.config.ui = {}
    c:take()
    T.require 'hub.ui.cmdline'.execute 'whois alice'
    c:recv ':srv 311 me alice a h.example * :Alice'
    c:recv ':srv 318 me alice :End of /WHOIS list.'
    local data, kind = control.detail().data, control.detail().kind

    HUB.current.routes['ui.draw']()
    local band
    for y = 0, detail_pad().h - 1 do
        local row = fake_ncurses.row(detail_pad(), y)
        if row:find('✕', 1, true) then band = row end
    end
    T.ok(band, 'a close button')
    T.ok(not band:find('─', 1, true), 'no line')
    T.ok(band:find('^  ✕  %S'), 'close first, then the title: ' .. band)
    T.ok(band:find(' DISCARD  $'), 'DISCARD at the right: ' .. band)

    -- the row of the band on the screen, found by clicking at a column
    local function click_band(column)
        for y = 0, tty_height - 2 do
            HUB.current.routes['ui.entry']('on_mouse', y, column, false)
            if not control.detail() then return y end
        end
    end

    T.ok(click_band(2), 'close at the left')
    T.ok(log.holds_detail(data), 'closed, not dropped')

    control.open_detail(kind, 'test', data)
    HUB.current.routes['ui.draw']()
    T.ok(click_band(utf8.len(band, 1, band:find('DISCARD', 1, true))), 'DISCARD at the right')
    T.ok(not log.holds_detail(data), 'closed and dropped')
end)

T.case('a long /quote line leaves room on the rule for the filter', function()
    local c = boot_labeled()
    local control = T.require 'hub.ui.control'
    T.require 'hub.ui.cmdline'.execute('quote PRIVMSG #c :' .. string.rep('long ', 80))
    c:take()
    c:recv '@label=sc1 :srv ACK'
    control.detail().filter = 'x'
    HUB.current.routes['ui.draw']()
    local visible
    for y = 0, detail_pad().h - 1 do
        local row = fake_ncurses.row(detail_pad(), y)
        if row:find('[CLOSE]', 1, true) then
            visible = row:sub(1, (utf8.offset(row, tty_width + 1) or #row + 1) - 1)
        end
    end
    T.ok(visible and visible:find('filter "x"', 1, true), 'on screen: ' .. tostring(visible))
end)

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
    T.ok(text:find('you: @me  as op', 1, true), 'our own status')
    c:recv ':srv MODE #chan +v me'
    T.ok(detail_text():find('you: @+me  as op, voice', 1, true), 'live')
    c:recv ':srv MODE #chan -ov me me'
    T.ok(detail_text():find('you: me  as member', 1, true), 'none')
    c:recv ':srv MODE #chan +o me'
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

T.case('a topic is not fetched, none, or set', function()
    local c = boot()
    local cmdline = T.require 'hub.ui.cmdline'
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    control.set_talk_target('test', '#chan')
    cmdline.execute 'chaninfo'
    T.ok(detail_text():find('topic: not fetched [↻]', 1, true), 'before the join is done')
    c:recv ':srv 366 me #chan :End of /NAMES list.'
    T.ok(detail_text():find('topic: none [↻]', 1, true), 'a join with no topic has none')

    c:recv ':alice!a@h TOPIC #chan :a topic'
    c:recv ':srv 333 me #chan alice!a@h 1700000000'
    T.ok(detail_text():find('topic: a topic [↻]', 1, true), 'set')
    T.ok(detail_text():find('set by: alice', 1, true), 'and by whom')
    c:recv ':srv 331 me #chan :No topic is set.'
    T.ok(detail_text():find('topic: none [↻]', 1, true), 'RPL_NOTOPIC empties it')
    T.ok(not detail_text():find('set by', 1, true), 'and who set it')

    -- a join's end of names leaves a topic alone
    c:recv ':srv 332 me #chan :again'
    c:recv ':srv 366 me #chan :End of /NAMES list.'
    T.ok(detail_text():find('topic: again', 1, true), 'kept')

    c:take()
    local y = 0
    for row in detail_text():gmatch '[^\n]*' do
        local x = row:find('topic:', 1, true) and row:find('[↻]', 1, true)
        if x then
            HUB.current.routes['ui.entry']('on_mouse', y, x, false)
            break
        end
        y = y + 1
    end
    T.eq(c:take(), {'TOPIC #chan'}, 'asked again from its button')
end)

T.case('channel information for a channel we are not in is a snapshot', function()
    local c = boot()
    local chat = T.require 'hub.features.chat'
    local cmdline = T.require 'hub.ui.cmdline'
    local control = T.require 'hub.ui.control'
    local irc_model = T.require 'hub.net.irc'
    local irc = HUB.state.nets.test.irc
    c:recv ':srv 005 me CHANMODES=eIbq,k,flj,mnst PREFIX=(ov)@+ :are supported'
    c:recv ':me!u@h JOIN #home'
    c:recv ':srv 366 me #home :End of /NAMES list.'
    c:take()
    control.set_talk_target('test', '#home')

    -- replies for a channel nobody asked about aren't kept
    c:recv ':srv 324 me #other +nt'
    T.eq(irc_model.known_channel(irc, '#other'), nil, 'unasked')

    -- the buffer opens in the background, without joining
    cmdline.execute 'chaninfo #Ext'
    T.eq(c:take(), {'MODE #Ext', 'TOPIC #Ext'}, 'asks for modes and topic')
    T.ok(chat.buffer('test', '#ext'), 'a buffer')
    T.eq(control.talk_target('test'), '#home', 'focus stays')
    T.eq(irc_model.get_channel(irc, '#ext'), nil, 'not joined')
    T.eq({control.detail().kind, control.detail().data.name}, {'channel', '#Ext'}, 'shown')
    local text = detail_text()
    T.ok(text:find('status: not joined', 1, true), text)
    T.ok(text:find('topic: not fetched [↻]', 1, true), 'nothing yet')
    T.ok(text:find('modes: not known', 1, true), 'nothing yet')
    T.ok(not text:find('members:', 1, true), 'no members')
    T.ok(not text:find('you:', 1, true), 'not us')

    c:recv ':srv 324 me #ext +ntk sekrit'
    c:recv ':srv 329 me #ext 1600000000'
    c:recv ':srv 332 me #ext :their topic'
    c:recv ':srv 333 me #ext alice!a@h 1700000000'
    c:recv ':srv 367 me #ext *!*@bad.example op!o@h 1700000000'
    c:recv ':srv 368 me #ext :End of Channel Ban List'
    text = detail_text()
    T.ok(text:find 'topic: their topic fetched %d+s ago', text)
    T.ok(text:find 'modes: k=sekrit n t fetched %d+s ago', text)
    T.ok(text:find 'bans: 1 entry fetched %d+s ago', text)
    T.ok(text:find('created: ', 1, true), 'created')

    -- /chaninfo again asks for the lists it has too
    cmdline.execute 'chaninfo #Ext'
    T.eq(c:take(), {'MODE #Ext', 'TOPIC #Ext', 'MODE #Ext +b'}, 'again')

    -- no topic: said so, not left as it was
    c:recv ':srv 331 me #ext :No topic is set.'
    T.ok(detail_text():find('topic: none', 1, true), 'none')

    -- our changes ask again, since no broadcast comes back
    T.command('mode +m', 'test', '#Ext')
    T.eq(c:take(), {'MODE #Ext +m', 'MODE #Ext', 'TOPIC #Ext', 'MODE #Ext +b'}, '/mode')
    T.command('topic new', 'test', '#Ext')
    T.eq(c:take(), {'TOPIC #Ext new', 'MODE #Ext', 'TOPIC #Ext', 'MODE #Ext +b'}, '/topic')
    T.command('ban *!*@x', 'test', '#Ext')
    T.eq(c:take(), {'MODE #Ext +b *!*@x', 'MODE #Ext', 'TOPIC #Ext', 'MODE #Ext +b'}, '/ban')
    chat.unset_list('test', '#Ext', 'b', '*!*@bad.example')
    T.eq(c:take(), {'MODE #Ext -b *!*@bad.example', 'MODE #Ext', 'TOPIC #Ext', 'MODE #Ext +b'}, '[x]')
    T.eq(T.log_lines 'error', {}, 'no errors')

    -- a refusal shows in the buffer
    c:recv ':srv 482 me #ext :You are not a channel operator'
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    T.ok(OrderedMap.size(chat.buffer('test', '#ext').messages) > 0, 'refused, in the buffer')

    -- closing the buffer forgets it and sends no PART
    chat.close('test', '#ext')
    T.eq(c:take(), {}, 'no PART')
    T.eq(irc_model.known_channel(irc, '#ext'), nil, 'forgotten')
    T.ok(detail_text():find('Not in this channel', 1, true), 'the pane says so')
    local y = 0
    for row in detail_text():gmatch '[^\n]*' do
        local x = row:find('[↻]', 1, true)
        if x then
            HUB.current.routes['ui.entry']('on_mouse', y, x, false)
            break
        end
        y = y + 1
    end
    T.eq(c:take(), {'MODE #Ext', 'TOPIC #Ext'}, 'its button looks again')
    T.ok(chat.buffer('test', '#ext'), 'with a buffer again')

    -- joining replaces the snapshot, and a join's PART doesn't bring it back
    c:recv ':srv 324 me #ext +nt'
    c:recv ':me!u@h JOIN #ext'
    c:recv ':srv 366 me #ext :End of /NAMES list.'
    T.eq(irc_model.observed_channel(irc, '#ext'), nil, 'no snapshot once joined')
    T.ok(irc_model.get_channel(irc, '#ext'), 'joined')
    T.ok(not detail_text():find('not joined', 1, true), 'the pane follows')
    c:take()
    T.command('mode +m', 'test', '#ext')
    T.eq(c:take(), {'MODE #ext +m'}, 'broadcasts tell us now')
    c:recv ':me!u@h PART #ext'
    T.eq(irc_model.known_channel(irc, '#ext'), nil, 'parted')
end)

T.run()
