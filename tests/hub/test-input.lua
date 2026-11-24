-- The input line: keys, prompts, typing modes and STATUSMSG, pastes, and
-- how a line being typed shows its formatting and where it would be cut.
--
-- Run with:  snowcone tests/hub/test-input.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local V = dofile(here .. '/viewlib.lua')(T, here)
local FakeTransport, fake_ncurses, ncurses, boot = V.FakeTransport, V.fake_ncurses, V.ncurses, V.boot
local key, type_text, status_bar, detail_text = V.key, V.type_text, V.status_bar, V.detail_text

T.case('the input line shows the cursor past 1024 cells', function()
    boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    HUB.state.ui.input.mode = 'command'
    editor.insert(control.editor(), string.rep('x', 3000) .. 'END')
    HUB.current.routes['ui.draw']()
    local found
    for _, win in ipairs(fake_ncurses.windows) do
        if win.kind == 'newpad' and win.h == 1 and fake_ncurses.row(win, 0):find('END', 1, true) then
            found = win
        end
    end
    T.ok(found, 'the end of the line is drawn')
    T.ok(found and found.w >= 3003, 'in a pad wide enough')
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

    -- T sends a notice
    key(string.byte 'T')
    T.eq(HUB.state.ui.input.mode, 'notice', 'notice mode')
    type_text 'heads up'
    key(13)
    sent = c:take()
    T.eq(sent[#sent], 'NOTICE #chan :heads up', 'sent as a notice')
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

    -- Meta-H shows the hidden messages of the buffer shown, and again
    -- hides them
    c:recv ':carol!c@h JOIN #chan'
    local chan = T.require 'hub.features.chat'.buffer('test', control.talk_target 'test')
    key(-string.byte 'h')
    T.eq(control.view_state 'buffer'.showing[chan], true, 'showing')
    HUB.current.routes['ui.draw']()
    key(-string.byte 'h')
    T.eq(control.view_state 'buffer'.showing[chan], nil, 'hidden again')

    -- F1 picks the first view of the rotation
    key(-ncurses.KEY_F1)
    T.eq(HUB.state.ui.view, control.rotation()[1], 'F1')
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('Meta-C-k closes the shown buffer, except while typing', function()
    local c = boot()
    local chat = T.require 'hub.features.chat'
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    local ctrl_k <const> = 0x1f & string.byte 'K'
    c:recv ':me!u@h JOIN #a'
    c:recv ':me!u@h JOIN #b'
    control.set_view 'buffer'
    control.set_talk_target('test', '#a')
    c:take()

    key(ctrl_k)
    T.eq(control.talk_target 'test', '#a', 'C-k alone keeps the buffer')
    T.eq(c:take(), {}, 'C-k alone sends nothing')

    key(-ctrl_k)
    T.eq(c:take(), {'PART #a'}, 'parts the channel')
    T.eq(chat.buffer('test', '#a'), nil, 'the buffer is gone')
    T.eq(control.talk_target 'test', '#b', 'moves on')

    -- in an input mode the line stays with its buffer
    key(string.byte 't')
    type_text 'hello'
    key(-ctrl_k)
    T.eq(editor.content(control.editor()), 'hello', 'keeps the line')
    T.eq(control.talk_target 'test', '#b', 'keeps the buffer')
    T.eq(c:take(), {}, 'nothing sent')
    key(0x1f & string.byte 'G')

    key(-ctrl_k)
    T.eq(control.talk_target 'test', nil, 'none left')
    c:take()
    key(-ctrl_k)
    T.eq(c:take(), {}, 'with no buffer it does nothing')
end)

T.case('a prompt goes when its task is canceled', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        registration = {password = {prompt = 'server password'}},
        identity = {nick = 'me'},
    }}}}
    local input = HUB.state.ui.input
    T.eq(input.mode, 'password', 'prompting')
    T.require 'hub.net.manager'.disconnect 'test'
    T.eq(input.mode, nil, 'gone with its task')
    T.eq(input.prompts, {}, 'queue empty')
end)

T.case('C-s leaves a prompt in place', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        registration = {password = {prompt = 'server password'}},
        identity = {nick = 'me'},
    }}}}
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

T.case('talk and action modes tell the buffer we are typing; quiet talk mode does not', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :message-tags'
    c:recv ':srv CAP me ACK :message-tags'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':me!u@h JOIN #chan'
    c:take()
    local control = T.require 'hub.ui.control'
    local clock = T.require 'hub.runtime.clock'
    local now = clock.now()
    clock.now = function() return now end
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'
    -- What the second's tick sends, but for its lag check's PING
    local function tick()
        T.require 'hub.runtime.bus'.emit('clock.tick', {now = now})
        local sent = {}
        for _, line in ipairs(c:take()) do
            if not line:find '^PING' then table.insert(sent, line) end
        end
        return sent
    end

    key(string.byte 't')
    T.eq(tick(), {}, 'not on entering the mode')
    key(0x1b)
    T.eq(c:take(), {}, 'nor on leaving it before typing')
    key(string.byte 't')
    type_text 'x'
    key(0x7f)
    T.eq(c:take(), {'@+typing=active TAGMSG #chan', '@+typing=done TAGMSG #chan'}, 'a character typed and erased')
    key(0x1b)
    T.eq(c:take(), {}, 'and done only once')

    key(string.byte 't')
    type_text 'hi'
    T.eq(c:take(), {'@+typing=active TAGMSG #chan'}, 'talk mode')
    now = now + 10
    T.eq(tick(), {'@+typing=paused TAGMSG #chan'}, 'paused, on the tick')
    key(13)
    T.eq(c:take(), {'PRIVMSG #chan hi'}, 'the message ends it')

    key(string.byte 't')
    key(-ncurses.KEY_UP)
    T.eq(tick(), {}, 'not for a line recalled from history')
    type_text '!'
    T.eq(c:take(), {'@+typing=active TAGMSG #chan'}, 'but once it is changed')
    key(0x1f & string.byte '_')
    T.eq(c:take(), {'@+typing=done TAGMSG #chan'}, 'done when undone back to the line recalled')
    type_text '?'
    key(-ncurses.KEY_DOWN)
    T.eq(c:take(), {'@+typing=active TAGMSG #chan', '@+typing=done TAGMSG #chan'},
        'and when browsing on to the empty line being typed')
    key(0x1b)

    key(string.byte 'a')
    type_text 'waves'
    key(0x1b)
    T.eq(c:take(), {'@+typing=active TAGMSG #chan', '@+typing=done TAGMSG #chan'}, 'action mode, ended by Esc')

    key(-string.byte 't')
    T.eq(HUB.state.ui.input.mode, 'quiet', 'Meta-T')
    type_text 'shh'
    key(13)
    key(string.byte 'T')
    type_text 'note'
    key(13)
    T.eq(c:take(), {'PRIVMSG #chan shh', 'NOTICE #chan note'}, 'neither quiet talk nor notice mode')
end)

T.case('@ and + toggle sending to STATUSMSG, per buffer, until Esc', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test',
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :message-tags'
    c:recv ':srv CAP me ACK :message-tags'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me STATUSMSG=@ :are supported'
    c:recv ':srv 376 me :End of MOTD'
    c:recv ':me!u@h JOIN #chan'
    c:recv ':bob!b@h PRIVMSG me :hi'
    c:take()
    local control = T.require 'hub.ui.control'
    local chat = T.require 'hub.features.chat'
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'

    key(string.byte '@')
    T.eq(control.statusmsg 'test', '@', 'on')
    T.ok(status_bar():find(' @#chan ', 1, true), 'before the name')
    key(string.byte 't')
    type_text 'ops only'
    T.ok(status_bar():find(' talk @ ', 1, true), 'in the input mode')
    T.eq(c:take(), {}, 'no typing notice')
    key(13)
    T.eq(c:take(), {'PRIVMSG @#chan :ops only'}, 'sent behind the prefix')
    local buffer = chat.buffer('test', '#chan')
    ---@cast buffer -nil joined above
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local echo = OrderedMap.get(buffer.messages, OrderedMap.last(buffer.messages))
    T.eq(echo.statusmsg, '@', 'shown in the channel, marked')
    T.eq(control.statusmsg 'test', '@', 'kept after a line')

    key(string.byte '+')
    T.eq(control.statusmsg 'test', '@', 'a prefix the server lacks is refused')
    T.eq(#T.log_lines 'error', 1, 'with an error')

    control.set_talk_target('test', 'bob')
    T.eq(control.statusmsg 'test', nil, 'each buffer has its own')
    key(string.byte '@')
    T.eq(control.statusmsg 'test', nil, 'a query takes none')
    control.set_talk_target('test', '#chan')
    T.eq(control.statusmsg 'test', '@', 'back in the channel, still on')

    key(string.byte '@')
    T.eq(control.statusmsg 'test', nil, 'toggled off')
    key(string.byte '@')
    key(string.byte 't')
    key(0x1f & string.byte 'G')
    T.eq(control.statusmsg 'test', '@', 'C-g leaves the input mode but keeps it')
    key(string.byte 't')
    key(0x1b)
    T.eq({HUB.state.ui.input.mode, control.statusmsg 'test'}, {nil, nil}, 'Esc leaves the mode and clears it')
    T.ok(not status_bar():find('@#chan', 1, true), 'and the name is plain')

    key(string.byte '@')
    chat.close('test', '#chan')
    chat.open('test', '#chan')
    control.set_talk_target('test', '#chan')
    T.eq(control.statusmsg 'test', nil, 'closing a buffer forgets it')
end)

T.case('pastes go to the editor up to a newline; an oversized one is reported', function()
    boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    key(string.byte '/')
    HUB.current.routes['ui.entry']('on_paste', 'say hi\nsecond line')
    T.eq(editor.content(control.editor()), 'say hi', 'pasted up to the newline')
    T.eq(T.log_lines 'error', {'paste cut at its first line break'}, 'and says so')
    HUB.current.routes['ui.entry']('on_paste', ' more\r\n')
    T.eq(editor.content(control.editor()), 'say hi more', 'a closing line break is no cut')
    T.eq(#T.log_lines 'error', 1, 'so not reported')
    HUB.current.routes['ui.entry']('on_paste', nil, 70000)
    T.eq(T.log_lines('error')[2], 'paste: a paste of 70000 bytes was discarded (limit 64 KiB)', 'reported')
    T.eq(editor.content(control.editor()), 'say hi more', 'editor unchanged')

    editor.reset(control.editor())
    HUB.current.routes['ui.entry']('on_paste', 'a\xffb\xe2\x82')
    T.eq(editor.content(control.editor()), 'a\u{FFFD}b\u{FFFD}\u{FFFD}', 'invalid UTF-8 replaced')

    editor.reset(control.editor())
    local start = os.clock()
    HUB.current.routes['ui.entry']('on_paste', string.rep('é', 16000))
    T.eq(editor.size(control.editor()), 16000, 'a big paste whole')
    T.ok(os.clock() - start < 2, 'and quickly: ' .. (os.clock() - start))
    editor.undo(control.editor())
    T.eq(editor.content(control.editor()), '', 'undone at once')
end)

T.case('the line being typed shows its formatting, codes and all', function()
    boot()
    local addircstr = T.require 'hub.ui.irc_formatting'
    local calls
    rawset(ncurses, 'colorset', function(fore, back) table.insert(calls, fore .. ',' .. back) end)
    local function drawn(str, mark)
        calls = {}
        local win = ncurses.newwin(1, 80)
        local x = addircstr(win, str, {mark = mark, color = 7})
        return fake_ncurses.row(win, 0), x, table.concat(calls, ' ')
    end
    local text, x, sets = drawn('a\x0304,12b\x02c', 1)
    T.eq(text, 'a␃04,12b␂c', 'a glyph per code, its numbers as typed')
    T.eq(x, 1, 'the cursor after the first byte')
    T.eq(sets, '7,-1 9,12', 'the default is the mode color')
    T.eq(select(3, drawn('\x0399,04x', 0)), '7,-1 7,9', 'and so is 99')
    T.eq(select(2, drawn('a\x0304b', 3)), 3, 'the cursor among the digits')
    T.eq(select(2, drawn('ab', 2)), 2, 'the cursor at the end')
    T.eq(select(2, drawn('é\u{85}x', 4)), 2, 'C1 scrubbed, the cursor still by code point')
    T.eq((drawn('\x04FFc', 0)), '␄FFc', 'a short hex color shows its text')
    rawset(ncurses, 'colorset', nil)
end)

T.case('the marker of a cut falls between the bytes it is given', function()
    boot()
    local addircstr = T.require 'hub.ui.irc_formatting'
    local function drawn(str, mark, cut)
        local win = ncurses.newwin(1, 80)
        local x = addircstr(win, str, {mark = mark, color = 7, cut = cut})
        return fake_ncurses.row(win, 0), x
    end
    T.eq({drawn('abcd', 0, 2)}, {'ab|cd', 0}, 'the cursor before it')
    T.eq({drawn('abcd', 4, 2)}, {'ab|cd', 5}, 'the cursor after it')
    T.eq({drawn('abcd', 2, 2)}, {'ab|cd', 3}, 'the cursor on the first character lost')
    T.eq((drawn('a\x02b', 0, 1)), 'a|␂b', 'before a code')
    T.eq((drawn('\x0304ab', 0, 2)), '␃0|4ab', 'among the digits of a color')
    T.eq((drawn('abcd', 1)), 'abcd', 'no marker without a cut')
end)

T.case('a line too long for the server to relay whole shows where it is cut', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    local function input_rows()
        HUB.current.routes['ui.draw']()
        local bar, line
        for i = #fake_ncurses.windows, 1, -1 do
            local win = fake_ncurses.windows[i]
            if win.h == 1 and win.kind == 'newwin' then bar = bar or fake_ncurses.row(win, 0) end
            if win.h == 1 and win.kind == 'newpad' then line = line or fake_ncurses.row(win, 0) end
        end
        return bar, line
    end
    local function typed(mode, text)
        control.set_input_mode(mode)
        local ed = control.editor()
        editor.reset(ed)
        editor.insert(ed, text)
        return input_rows()
    end

    -- :me!u@h PRIVMSG #chan :\r\n is 25 bytes of the 50
    c:recv ':srv 005 me LINELEN=50 :are supported'
    c:recv ':me!u@h JOIN #chan'
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'
    local function x(n) return string.rep('x', n) end

    local bar, line = typed('talk', x(25))
    T.eq(line, x(25), 'a line that just fits has no marker')
    T.ok(not bar:find(' talk -', 1, true), 'and no count')

    bar, line = typed('talk', x(30))
    T.eq(line, x(25) .. '|' .. x(5), 'the marker at the cut')
    T.ok(bar:find(' talk -5 ', 1, true), 'how far over')

    bar, line = typed('action', x(20))
    T.eq(line, x(16) .. '|' .. x(4), 'an action has less room')
    T.ok(bar:find(' action -4 ', 1, true), 'by what it adds')

    _, line = typed('notice', x(27))
    T.eq(line, x(26) .. '|x', 'NOTICE is a byte shorter than PRIVMSG')

    bar, line = typed('talk', x(24) .. 'é')
    T.eq(line, x(24) .. '|é', 'a character the cut would break goes whole')
    T.ok(bar:find(' talk -1 ', 1, true), 'and the count is of bytes')

    control.set_statusmsg('test', '@')
    _, line = typed('talk', x(25))
    T.eq(line, x(24) .. '|x', 'a STATUSMSG prefix goes out too')
    control.set_statusmsg('test', nil)

    -- what the server says of our mask moves the cut
    c:recv ':me!u@h CHGHOST user host'
    _, line = typed('talk', x(25))
    T.eq(line, x(19) .. '|' .. x(6), 'CHGHOST, whose source shows the old mask')
    c:recv ':srv 396 me a.b :is now your hidden host'
    _, line = typed('talk', x(25))
    T.eq(line, x(20) .. '|' .. x(5), 'a hidden host keeps the user')
    c:recv ':me!u@h PRIVMSG #chan :echo'
    _, line = typed('talk', x(25))
    T.eq(line, x(25), 'any line of ours shows the mask')

    c:recv ':srv BATCH +h chathistory #chan'
    c:recv '@batch=h :me!olduser@a.very.long.old.host PRIVMSG #chan :old'
    c:recv ':srv BATCH -h'
    _, line = typed('talk', x(25))
    T.eq(line, x(25), 'but not a line from history, with the mask of back then')

    _, line = typed('command', x(60))
    T.eq(line, x(60), 'a command has no marker')
    editor.reset(control.editor())
    control.set_input_mode()
end)

T.case('Enter leaves a line too long to reach others whole, unsent', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    c:recv ':srv 005 me LINELEN=50 :are supported'
    c:recv ':me!u@h JOIN #chan'
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'
    c:take()

    local function enter(mode, text)
        control.set_input_mode(mode)
        local ed = control.editor()
        editor.reset(ed)
        editor.insert(ed, text)
        key(13)
        return ed
    end
    local long = string.rep('x', 26)
    for _, mode in ipairs {'talk', 'quiet', 'action', 'notice'} do
        local text = mode == 'notice' and long .. 'x' or long
        local history = OrderedMap.size(control.editor().history)
        local ed = enter(mode, text)
        T.eq(c:take(), {}, mode .. ': nothing goes out')
        T.eq(HUB.state.ui.input.mode, mode, mode .. ': still in the mode')
        T.eq(editor.content(ed), text, mode .. ': the line is kept')
        T.eq(OrderedMap.size(ed.history), history, mode .. ': and not in history yet')
    end
    local errors = T.log_lines 'error'
    T.eq(errors[#errors], 'not sent: the line is too long by 1 byte', 'says why')

    enter('talk', long)
    key(0x7f)
    key(13)
    T.eq(c:take(), {'PRIVMSG #chan ' .. string.rep('x', 25)}, 'shortened, it goes')
    T.eq(HUB.state.ui.input.mode, nil, 'and the mode ends')

    -- nothing to measure against, so the send's own rules apply
    control.set_talk_target('test', nil)
    local ed = enter('talk', long)
    T.eq(HUB.state.ui.input.mode, nil, 'without a buffer the line is not held')
    T.eq(editor.content(ed), '', 'as before')
end)

T.case('with our mask unknown, the room is for the longest', function()
    local c = boot()
    local irc_model = T.require 'hub.net.irc'
    local irc = HUB.state.nets.test.irc
    -- :me! PRIVMSG #chan :\r\n is 22 bytes, around user@host
    T.eq(irc_model.text_room(irc, 'PRIVMSG', '#chan'), 512 - 22 - (10 + 1 + 63), 'by default')
    c:recv ':srv 005 me USERLEN=12 HOSTLEN=20 :are supported'
    T.eq(irc_model.text_room(irc, 'PRIVMSG', '#chan'), 512 - 22 - (12 + 1 + 20), 'by what the server says')
end)

T.case('the formatting palette puts codes in at the cursor', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    c:recv ':me!u@h JOIN #chan'
    control.set_talk_target('test', '#chan')
    control.set_view 'buffer'

    key(-string.byte 'p')
    T.eq(control.detail() and control.detail().kind, 'format', 'Meta-P opens it')
    local function click(label)
        local y = 0
        for row in detail_text():gmatch '[^\n]*' do
            local x = row:find(label, 1, true)
            if x then
                HUB.current.routes['ui.entry']('on_mouse', y, x, false)
                return
            end
            y = y + 1
        end
        error('no ' .. label)
    end
    local function line() return editor.content(control.editor()) end

    T.ok(detail_text():find('at the cursor: plain', 1, true), 'plain to begin with')
    click '[bold]'
    T.eq(HUB.state.ui.input.mode, 'talk', 'a click starts talking')
    click ' red '
    type_text '5 apples'
    T.eq(line(), '\x02\x03045 apples', 'two digits, so a typed digit stays text')
    T.ok(detail_text():find('at the cursor: bold, red', 1, true), 'the cursor is in bold red')

    click 'background: default'
    click ' blue '
    T.eq(line(), '\x02\x03045 apples\x0304,02', 'the background keeps the text color')
    T.ok(detail_text():find('[text: red|background: blue]', 1, true), 'the switch shows both')
    click ' green '
    T.eq(line(), '\x02\x03045 apples\x0304,03', 'picking again changes the code before the cursor')
    click 'text: red'
    click ' yellow '
    T.eq(line(), '\x02\x03045 apples\x0308,03', 'and keeps its background')
    key(0x1f) -- C-_
    key(0x1f)
    T.eq(line(), '\x02\x03045 apples\x0304,02', 'each pick undoes alone')
    type_text ' x'
    click ' white '
    click 'background: blue'
    click ' black '
    T.eq(line():sub(-14), '\x0304,02 x\x0300,01', 'text then background: one code')
    click 'text: white'
    key(-ncurses.KEY_HOME)
    key(-ncurses.KEY_RIGHT)
    type_text ',x'
    key(-ncurses.KEY_LEFT)
    key(-ncurses.KEY_LEFT)
    click ' green '
    T.eq(line():sub(1, 9), '\x02\x0303,99,x', 'before a comma, the background goes in too')
    key(0x1f) -- C-_: one click is one undo
    T.eq(line():sub(1, 4), '\x02,x\x03', 'undone at once')

    -- the input line draws it formatted
    HUB.current.routes['ui.draw']()
    local textbox
    for _, win in ipairs(fake_ncurses.windows) do
        if win.kind == 'newpad' and win.h == 1 then textbox = win end
    end
    T.ok(fake_ncurses.row(textbox, 0):find('␂,x␃045 apples', 1, true), 'shown with its glyphs')

    key(-string.byte 'p')
    T.eq(control.detail(), nil, 'Meta-P closes it')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

-- How cmdline sees a command line, cursor at the end unless given: each
-- span as role[text], then the placeholders, after a bar when there is one
local function look_of(text, cursor)
    local cmdline = T.require 'hub.ui.cmdline'
    local look = cmdline.decorate(text, cursor or #text)
    local parts = {}
    for _, s in ipairs(look.spans) do
        table.insert(parts, s.role .. '[' .. text:sub(s.lo, s.hi) .. ']')
    end
    local ghosts = {}
    for _, g in ipairs(look.ghosts) do
        table.insert(ghosts, (g.optional and '?' or '') .. g.label .. (g.repeats and '*' or ''))
    end
    if ghosts[1] then
        table.insert(parts, (look.ghost_sep and '| ' or '') .. table.concat(ghosts, ' '))
    end
    return table.concat(parts, ' ')
end

T.case('a command line shows its command, arguments and what is still to type', function()
    boot()
    T.eq(look_of 'msg', 'good[msg] | target text', 'a known command, its arguments to come')
    T.eq(look_of 'msg ', 'good[msg] sep[ ] target text', 'after a space')
    T.eq(look_of 'msg bo', 'good[msg] sep[ ] plain[bo] | text', 'a word fills its place')
    T.eq(look_of 'msg  bob hi \x02there', 'good[msg] sep[  ] plain[bob] sep[ ] text[hi \x02there]',
        'spaces are one bar; message text as typed')
    T.eq(look_of '  msg', 'plain[  ] good[msg] | target text', 'spaces before')
    T.eq(look_of 'kickban bob', 'good[kickban] sep[ ] plain[bob] | ?reason', 'optional')
    T.eq(look_of 'op a b', 'good[op] sep[ ] plain[a b] | ?nick*', 'repeating, in a rest')
    T.eq(look_of 'op a ', 'good[op] sep[ ] plain[a ] ?nick*', 'a space ending a rest, no bar')
    T.eq(look_of 'quote', 'good[quote] | ?@tags command ?arguments', 'a raw line to come')
    T.eq(look_of 'quote PRIVMSG ', 'good[quote] sep[ ] plain[PRIVMSG] sep[ ] ?arguments', 'the tags passed by')
    T.eq(look_of 'quote @a=b', 'good[quote] sep[ ] plain[@a=b] | command ?arguments', 'or given')
    T.eq(look_of 'quote PRIVMSG #c :hi  there ',
        'good[quote] sep[ ] plain[PRIVMSG] sep[ ] plain[#c] sep[ ] plain[:hi  there ]',
        'a word each, until the one after a colon')
    T.eq(look_of 'quote :x', 'good[quote] sep[ ] bad[:x] | ?arguments', 'a source, which it sends none of')
    T.eq(look_of 'quote @a :x', 'good[quote] sep[ ] plain[@a] sep[ ] bad[:x] | ?arguments', 'after tags too')
    T.eq(look_of 'quote PRIV_', 'good[quote] sep[ ] plain[PRIV_] | ?arguments', 'a command being typed')
    T.eq(look_of 'quote PRIV_ ', 'good[quote] sep[ ] bad[PRIV_] sep[ ] ?arguments', 'not of letters and digits')
    T.eq(look_of 'quote @a; ', 'good[quote] sep[ ] bad[@a;] sep[ ] command ?arguments', 'a tag without a key')

    T.eq(look_of "addwatch beep 'a b'", "good[addwatch] sep[ ] plain[beep] sep[ ] plain['a b'] | ?color ?[no]flash",
        'options in any order, and those still to give')
    T.eq(look_of "addwatch red bogus nobeep ", 'good[addwatch] sep[ ] plain[red] sep[ ] bad[bogus] sep[ ] '
        .. "plain[nobeep] sep[ ] 'pattern'|filter ?[no]flash", 'one that is no option')
    T.eq(look_of "addwatch 'a' beep nobeep 'b' ", "good[addwatch] sep[ ] plain['a'] sep[ ] plain[beep] sep[ ] "
        .. "plain[nobeep] sep[ ] plain['b'] sep[ ] ?color ?[no]flash", 'the last of each wins')
    T.eq(look_of "addwatch red'x' ", "good[addwatch] sep[ ] plain[red] plain['x'] sep[ ] ?[no]beep ?[no]flash",
        'a pattern against a word')
    T.eq(look_of "addwatch 'open", "good[addwatch] sep[ ] plain['open] | 'pattern'|filter ?color ?[no]beep ?[no]flash",
        'a pattern still being typed')
    local bad_pattern = T.require 'hub.lib.matching'.kind == 'pcre2' and '(' or '[a'
    T.eq(look_of("addwatch '" .. bad_pattern .. "'"),
        "good[addwatch] sep[ ] bad['" .. bad_pattern .. "'] | 'pattern'|filter ?color ?[no]beep ?[no]flash",
        'a pattern that does not compile, at once')
    T.command "addwatch 'a'"
    T.command "addwatch 'b' red nobeep"
    T.eq(look_of 'editwatch 2', "good[editwatch] sep[ ] plain[2] | ?'b' ?red ?nobeep ?[no]flash",
        'a watch to change, as it is now')
    T.eq(look_of 'editwatch 2 blue', "good[editwatch] sep[ ] plain[2] sep[ ] plain[blue] | ?'b' ?nobeep ?[no]flash",
        'what is given in place of how it is')
    T.eq(look_of 'editwatch 3', "good[editwatch] sep[ ] plain[3] | ?'pattern'|filter ?color ?[no]beep ?[no]flash",
        'one that may be, being typed')
    T.eq(look_of 'editwatch 3 red', "good[editwatch] sep[ ] bad[3] sep[ ] plain[red] | ?'pattern'|filter "
        .. '?[no]beep ?[no]flash', 'one there is not')
    T.eq(look_of 'delwatch 3 ', 'good[delwatch] sep[ ] bad[3] plain[ ]', 'nor to remove')
    T.eq(look_of 'editwatch 0x2 ',
        "good[editwatch] sep[ ] bad[0x2] sep[ ] ?'pattern'|filter ?color ?[no]beep ?[no]flash", 'a number as $i reads one')
    T.command [[addwatch "it's"]]
    T.eq(look_of 'editwatch 3', [[good[editwatch] sep[ ] plain[3] | ?"it's" ?color ?[no]beep ?[no]flash]],
        'a pattern in the quotes it can be typed in')
    T.eq(look_of 'editwatch 1 filter',
        'good[editwatch] sep[ ] plain[1] sep[ ] bad[filter] | '
        .. "?'a' ?color ?[no]beep ?[no]flash", 'no filter to take')
    T.require 'hub.ui.control'.set_filter('cliconn', 'badguy')
    T.eq(look_of 'editwatch 1 filter',
        'good[editwatch] sep[ ] plain[1] sep[ ] plain[filter] | ?color ?[no]beep ?[no]flash', 'the filter set')
    T.require 'hub.ui.control'.set_filter('cliconn', nil)
    T.eq(look_of 'spell bogus', 'good[spell] sep[ ] plain[bogus]', 'a word, nothing to come')

    T.eq(look_of 'ms', 'plain[ms]', 'the start of a command, being typed')
    T.eq(look_of('ms', 0), 'plain[ms]', 'the cursor at its start')
    T.eq(look_of 'ms bob', 'bad[ms] plain[ bob]', 'unknown once past it')
    T.eq(look_of 'zz', 'bad[zz]', 'nor the start of one')
    T.eq(look_of 'zz@test x', 'bad[zz@test] plain[ x]', 'a network named and all')
    T.eq(look_of '@test x', 'bad[@test] plain[ x]', 'or no name before it')

    T.eq(look_of 'delwatch x', 'good[delwatch] sep[ ] plain[x]', 'a word that may still become right')
    T.eq(look_of 'delwatch x ', 'good[delwatch] sep[ ] bad[x] plain[ ]', 'and once past it')
    T.eq(look_of 'whois a b  c', 'good[whois] sep[ ] plain[a] sep[ ] bad[b  c]', 'what is left over is one')
    T.eq(look_of 'quit now', 'good[quit] sep[ ] bad[now]', 'arguments to a command with none')

    T.eq(look_of 'msg@test bob', 'good[msg] good[@test] sep[ ] plain[bob] | text', 'a network named')
    T.eq(look_of 'msg@te', 'good[msg] plain[@te] | target text', 'one being typed')
    T.eq(look_of 'msg@nope ', 'good[msg] bad[@nope] sep[ ] target text', 'no such network')
    T.eq(look_of 'reload@test', 'good[reload] bad[@test] | ?file', 'a command that takes none')
    T.eq(look_of '', '', 'nothing')

    T.boot {ui = true}
    T.eq(look_of 'whois', 'warn[whois] | nick', 'a network command with no network')
end)

T.case('a command line shows nothing wrong and nothing required to come just when Enter takes it', function()
    local c = boot()
    c:recv ':srv 005 me PREFIX=(ov)@+ CHANMODES=beIq,k,flj,imnpst :are supported'
    c:recv ':me!u@h JOIN #chan'
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    control.set_talk_target('test', '#chan')
    local bad_pattern = T.require 'hub.lib.matching'.kind == 'pcre2' and '(' or '[a'
    T.command "addwatch 'one'"

    -- the cursor elsewhere, so no word is still being typed
    local function shows_fine(text)
        local look = cmdline.decorate(text, -1)
        for _, span in ipairs(look.spans) do
            if span.role == 'bad' or span.role == 'warn' then return false end
        end
        for _, ghost in ipairs(look.ghosts) do
            if not ghost.optional then return false end
        end
        return true
    end
    local function taken(text)
        local before = #T.log_lines 'error'
        cmdline.execute(text)
        return #T.log_lines 'error' == before
    end
    for _, text in ipairs {
        "addwatch 'a'", "addwatch 'a' red beep", "addwatch 'a' beep nobeep 'b'", "addwatch red'x'",
        "addwatch '" .. bad_pattern .. "'", "addwatch bogus 'a'", 'addwatch filter', 'addwatch red',
        "addwatch 'a' 2", "addwatch 'open", "addwatch beep,red 'a'",
        'editwatch 1 red', "editwatch 1 'b' noflash", 'editwatch 1 bogus',
        'quote PRIVMSG #c :hi there', 'quote :src PRIVMSG x', 'quote @a=b PRIVMSG x :y', 'quote', 'quote @a=b',
        'quote A-B x', 'quote PRIV_MSG', 'quote @ X', 'quote @= X', 'quote @a;;b X', 'quote @a;b=c X',
        'quote X\tY', 'quote X \0Y',
        '@', '@test x', 'zz@test',
        'editwatch 99 red', 'editwatch 1', 'editwatch 0x1 red', 'editwatch +1 red', 'delwatch 99', 'delwatch 1',
    } do
        T.eq(shows_fine(text), taken(text), text)
    end
end)

T.case('a shape is for a command that can be used here', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {{
        id = 'test', features = {'chat'},
        server = {host = 'test.example', port = 6667},
        identity = {nick = 'me'},
    }}}}
    local common = T.require 'hub.features.common'
    T.eq(look_of 'editwatch 1 red', 'warn[editwatch] sep[ ] plain[1] sep[ ] plain[red] '
        .. '| ?color ?[no]beep ?[no]flash', 'not shaped where it cannot be used')
    T.eq(common.get_state('snotice', 'test'), nil, 'and the feature left alone')
end)

T.case('every command line shows nothing wrong and nothing required to come just when its spec fits', function()
    boot()
    local control = T.require 'hub.ui.control'
    local cmdline = T.require 'hub.ui.cmdline'
    local run = T.require 'hub.commands.run'
    local function shows_fine(text)
        local look = cmdline.decorate(text, -1)
        for _, span in ipairs(look.spans) do
            if span.role == 'bad' or span.role == 'warn' then return false end
        end
        for _, ghost in ipairs(look.ghosts) do
            if not ghost.optional then return false end
        end
        return true
    end
    -- what run.execute checks before the command's own fn
    local function fits(text)
        local line = run.split(text)
        local cmd = HUB.current.commands[line.name]
        if not cmd then return false end
        local net = control.current_net()
        if line.at then
            if cmd.scope ~= 'net' or not HUB.state.nets[line.at] then return false end
            net = line.at
        end
        if not run.available(cmd, net) or cmd.scope == 'net' and not net then return false end
        return cmd.pattern(line.args, {})
    end
    local names = {}
    for name, cmd in pairs(HUB.current.commands) do
        if not cmd.shape and not cmd.exists then table.insert(names, name) end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        for _, args in ipairs {'', ' x', ' x y', " 'a b'", " 'a", ' 1', ' -2 x', '@test', '@test x', '@nope x'} do
            local text = name .. args
            T.eq(shows_fine(text), fits(text), text)
        end
    end
end)

T.case('a command line is drawn with bars and dim placeholders', function()
    boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    local function drawn(text, cursor)
        control.set_input_mode 'command'
        local ed = control.editor()
        editor.reset(ed)
        editor.insert(ed, text)
        for _ = 1, #text - (cursor or #text) do editor.move_left(ed) end
        HUB.current.routes['ui.draw']()
        local textbox
        for _, win in ipairs(fake_ncurses.windows) do
            if win.kind == 'newpad' and win.h == 1 then textbox = win end
        end
        local _, x = ncurses.getyx(textbox)
        return fake_ncurses.row(textbox, 0), x, fake_ncurses.italics(textbox, 0)
    end
    T.eq({drawn 'msg'}, {'msg│target│text', 3, {}}, 'the cursor on the first placeholder')
    T.eq({drawn 'kickban  bob'}, {'kickban│ bob│reason', 12, {'reason'}}, 'optional in italics')
    T.eq({drawn('msg bob hi', 5)}, {'msg│bob│hi', 5, {}}, 'the cursor inside a word')
    T.eq({drawn('msg  bob', 4)}, {'msg│ bob│text', 4, {}}, 'and among the spaces')
    T.eq({drawn('msg bob h\x02i', 9)}, {'msg│bob│h␂i', 9, {}}, 'and in message text')
    T.eq({drawn 'op a'}, {'op│a│nick…', 4, {'nick…'}}, 'repeating')
    T.eq({drawn("addwatch red'x'", 12)}, {"addwatch│red'x'│[no]beep│[no]flash", 12, {'[no]beep', '[no]flash'}},
        'the cursor where two words touch')
    T.eq({drawn 'quote PRIVMSG '}, {'quote│PRIVMSG│arguments', 14, {'arguments'}}, 'a placeholder after a space')
    T.eq(T.log_lines 'error', {}, 'drawn')
end)

T.run()
