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
    T.eq(T.require 'hub.lib.OrderedMap'.size(input.secret.history), 0, 'secret not in history')
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
    typed 'x10000000000000041'
    editor.hexinput(ed)
    T.eq(editor.content(ed), 'x10000000000000041', 'too large, however many digits')

    typed '/join #ab'
    editor.confirm(ed)
    typed '/join #ba'
    editor.confirm(ed)
    T.eq(T.require 'hub.lib.OrderedMap'.size(ed.history), 2, 'an anagram of the last line is still new')
    typed '/join #ba'
    editor.confirm(ed)
    T.eq(T.require 'hub.lib.OrderedMap'.size(ed.history), 2, 'a repeat is not')

    for i = 1, 1005 do
        typed(tostring(i))
        editor.confirm(ed)
    end
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    T.eq(OrderedMap.size(ed.history), 1000, 'history is bounded')
    T.eq(utf8.char(table.unpack(OrderedMap.get_oldest(ed.history))), '6', 'oldest dropped first')
    T.eq(OrderedMap.get(ed.history, 7), nil, 'a dropped line is gone by its number')
    T.eq(OrderedMap.get(ed.history, 8), {0x36}, 'the oldest held keeps its number')
    T.eq(OrderedMap.get(ed.history, 1008), nil, 'nothing past the newest')
    editor.oldest_history(ed)
    T.eq({editor.content(ed), ed.at}, {'6', 8}, 'Meta-< to the oldest held')
end)

T.case('editor: recalling lines leaves history as it was', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local ed = editor.new()
    local function typed(text)
        for _, c in utf8.codes(text) do editor.add(ed, c) end
    end
    local function content() return editor.content(ed) end
    local function history()
        local t = {}
        for line in OrderedMap.reveach(ed.history) do table.insert(t, utf8.char(table.unpack(line))) end
        return t
    end
    for _, line in ipairs {'one', 'two', 'three'} do
        typed(line)
        editor.confirm(ed)
    end

    editor.older_history(ed)
    T.eq(content(), 'three', 'Up recalls the newest')
    editor.newer_history(ed)
    T.eq(content(), '', 'Down back to the empty line')
    editor.newer_history(ed)
    T.eq(content(), '', 'and no further')

    typed 'draft'
    editor.older_history(ed)
    editor.kill_to_beg(ed)
    typed 'changed'
    editor.older_history(ed)
    editor.kill_to_beg(ed) -- emptied, not dropped
    editor.older_history(ed)
    T.eq(content(), 'one', 'the oldest')
    editor.older_history(ed)
    T.eq(content(), 'one', 'and no further')
    editor.newer_history(ed)
    T.eq(content(), '', 'an emptied line stays empty while recalling')
    editor.newer_history(ed)
    T.eq(content(), 'changed', 'an edit kept while recalling')
    editor.newer_history(ed)
    T.eq(content(), 'draft', 'the draft back')
    T.eq(history(), {'one', 'two', 'three'}, 'history unchanged')

    editor.older_history(ed)
    editor.confirm(ed)
    T.eq(history(), {'one', 'two', 'three', 'changed'}, 'entering an edit adds a line')
    editor.older_history(ed)
    editor.older_history(ed)
    T.eq(content(), 'three', 'edits forgotten once a line is entered')
end)

T.case('editor: history ends', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local ed = editor.new()
    editor.oldest_history(ed)
    editor.older_history(ed)
    editor.newest_history(ed)
    T.eq({editor.content(ed), ed.at}, {'', nil}, 'empty history: nothing to recall')
end)

T.case('editor: kills and word motion', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local ed = editor.new()
    local function typed(text)
        editor.reset(ed)
        for _, c in utf8.codes(text) do editor.add(ed, c) end
    end
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    local function yanked()
        return utf8.char(table.unpack(OrderedMap.get(ed.kills, OrderedMap.last(ed.kills))))
    end

    typed 'one two'
    editor.kill_prev_word(ed)
    editor.kill_to_end(ed)
    T.eq(yanked(), 'two', 'C-k at the end keeps the kill')
    editor.move_to_beg(ed)
    editor.kill_to_beg(ed)
    editor.kill_prev_word(ed)
    T.eq(yanked(), 'two', 'so do C-u and C-w at the start')
    editor.move_to_end(ed)
    editor.kill_next_word(ed)
    T.eq(yanked(), 'two', 'and Meta-d at the end')
    editor.paste(ed)
    T.eq(editor.content(ed), 'one two', 'yanked back')

    typed 'one two three'
    editor.kill_prev_word(ed)
    editor.kill_prev_word(ed)
    T.eq(yanked(), 'two three', 'consecutive kills accumulate')

    typed 'hi nick_away: see #chan.x'
    editor.kill_prev_spaced_word(ed)
    T.eq(yanked(), '#chan.x', 'C-w kills back to a space')
    editor.kill_prev_word(ed)
    editor.kill_prev_word(ed)
    T.eq(editor.content(ed), 'hi nick_', 'Meta-Del stops at punctuation')

    typed 'dit café crème'
    editor.move_prev_word(ed)
    T.eq(ed.cursor, 10, 'Meta-b to the start of crème')
    editor.move_prev_word(ed)
    T.eq(ed.cursor, 5, 'and of café')
    editor.move_next_word(ed)
    T.eq(ed.cursor, 9, 'Meta-f past café')
end)

T.case('editor: undo and the kill ring', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local ed = editor.new()
    local function type_text(text)
        for _, c in utf8.codes(text) do editor.add(ed, c) end
    end
    local function content() return editor.content(ed) end
    local OrderedMap = T.require 'hub.lib.OrderedMap'

    type_text 'one two'
    editor.kill_prev_word(ed)
    type_text 'three'
    editor.undo(ed)
    T.eq(content(), 'one ', 'a run of typing undoes at once')
    editor.undo(ed)
    T.eq({content(), ed.cursor}, {'one two', 8}, 'then the kill')
    editor.undo(ed)
    T.eq(content(), '', 'then the first typing')
    editor.undo(ed)
    T.eq(content(), '', 'nothing more to undo')

    editor.backspace(ed)
    editor.move_left(ed)
    T.eq(OrderedMap.size(ed.undo), 0, 'no change, nothing to undo')

    -- kills one, two, three; then yanks back through them
    ed = editor.new()
    type_text 'one two three'
    editor.kill_prev_word(ed)
    editor.move_left(ed)
    editor.kill_prev_word(ed)
    editor.move_left(ed)
    editor.kill_prev_word(ed)
    T.eq(content(), '  ', 'all killed')
    editor.move_to_end(ed)
    editor.paste(ed)
    T.eq(content(), '  one', 'C-y the newest')
    editor.paste_older(ed)
    T.eq(content(), '  two', 'Meta-y the one before')
    editor.paste_older(ed)
    editor.paste_older(ed)
    T.eq({content(), ed.cursor}, {'  one', 6}, 'round to the newest')
    editor.undo(ed)
    T.eq(content(), '  three', 'undo steps back through Meta-y')
    editor.paste_older(ed)
    T.eq(content(), '  three', 'Meta-y only right after a yank')

    editor.reset(ed)
    T.eq(OrderedMap.size(ed.undo), 0, 'a new line starts with no undo')
    for i = 1, 150 do
        type_text(tostring(i % 10))
        editor.kill_prev_word(ed)
    end
    T.eq(OrderedMap.size(ed.undo), 100, 'undo is bounded')
    T.eq(OrderedMap.size(ed.kills), 60, 'so are kills')
    T.eq(OrderedMap.get(ed.kills, OrderedMap.last(ed.kills)), {0x30}, 'keeping the newest')

    -- the oldest kill held is the 91st, '1'; Meta-y wraps from it to the newest
    editor.paste(ed)
    for _ = 1, 59 do editor.paste_older(ed) end
    T.eq(content(), '1', 'Meta-y to the oldest kill held')
    editor.paste_older(ed)
    T.eq(content(), '0', 'then round to the newest')

    for _ = 1, 100 do editor.undo(ed) end
    T.eq(OrderedMap.size(ed.undo), 0, 'every change held undone')
    -- the paste and 60 Meta-y, then 39 of the kills and typing before them
    T.eq(content(), '1', 'back to before the oldest change held')
    editor.undo(ed)
    T.eq(content(), '1', 'and no further')
end)

T.case('editor: transposing words, case and the ends of history', function()
    boot {}
    local editor = T.require 'hub.ui.editor'
    local ed = editor.new()
    local function typed(text)
        editor.reset(ed)
        for _, c in utf8.codes(text) do editor.add(ed, c) end
    end
    local function at(text, i)
        typed(text)
        editor.move(ed, i)
    end

    at('one, two three', 6)
    editor.swap_words(ed)
    T.eq(editor.content(ed), 'two, one three', 'Meta-t swaps around the cursor')
    T.eq(ed.cursor, 9, 'and moves past them')
    typed 'one two  '
    editor.swap_words(ed)
    T.eq(editor.content(ed), 'two one  ', 'the last two at the end')
    at('one', 2)
    editor.swap_words(ed)
    T.eq({editor.content(ed), ed.cursor}, {'one', 2}, 'one word: nothing')

    at('hello wORLD', 1)
    editor.upcase_word(ed)
    T.eq({editor.content(ed), ed.cursor}, {'HELLO wORLD', 6}, 'Meta-u')
    editor.capitalize_word(ed)
    T.eq(editor.content(ed), 'HELLO World', 'Meta-c')
    at('ABC dÉF', 2)
    editor.downcase_word(ed)
    editor.downcase_word(ed)
    T.eq(editor.content(ed), 'Abc dÉf', 'Meta-l from the cursor, ASCII only')

    for _, line in ipairs {'first', 'second', 'third'} do
        typed(line)
        editor.confirm(ed)
    end
    typed 'draft'
    editor.oldest_history(ed)
    T.eq(editor.content(ed), 'first', 'Meta-< to the oldest')
    editor.newest_history(ed)
    T.eq(editor.content(ed), 'draft', 'Meta-> back to the draft')
    T.eq(T.require 'hub.lib.OrderedMap'.size(ed.history), 3, 'history unchanged')
end)

T.run()
