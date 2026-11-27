-- Spell checking ([spell]): the words of a line, misspellings underlined
-- while talking, Meta-$ and /spell. Needs snowcone built with hunspell,
-- and skips without it.
--
-- Run with:  snowcone tests/hub/test-spell.lua

if not myhunspell then
    print '1..0 # SKIP built without hunspell'
    os.exit(77)
end

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local fake_ncurses = dofile(here .. '/fake_ncurses.lua')
local path = require 'pl.path'

fake_ncurses.install(150, 40)

local dictionary = path.abspath(here .. '/fixtures/spell')

-- A personal list no case writes to unless it names its own
local unused = os.tmpname()
os.remove(unused)

local function boot(personal)
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {
        spell = {dictionary = dictionary, personal = personal or unused},
        networks = {{
            id = 'test',
            server = {host = 'test.example', port = 6667},
            identity = {nick = 'me'},
        }},
    }}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    return c
end

local function key(k)
    HUB.current.routes['ui.entry']('on_keyboard', k)
end

local function type_text(text)
    for _, c in utf8.codes(text) do key(c) end
end

local function meta(c)
    return -string.byte(c)
end

local function content()
    local control = T.require 'hub.ui.control'
    return T.require 'hub.ui.editor'.content(control.editor())
end

-- The input line's pad, after a draw
local function input_line()
    HUB.current.routes['ui.draw']()
    for i = #fake_ncurses.windows, 1, -1 do
        local win = fake_ncurses.windows[i]
        if win.kind == 'newpad' and win.h == 1 then return win end
    end
end

local function words_of(text)
    local t = {}
    for _, w in ipairs(T.require 'hub.lib.words'(text)) do
        table.insert(t, w.word)
        T.eq(text:sub(w.lo, w.hi), w.word, 'range of ' .. w.word)
    end
    return t
end

T.case('words leave out what is not prose', function()
    boot()
    T.eq(words_of "the dog's café, don't!", {'the', "dog's", 'café', "don't"}, 'apostrophes inside words')
    T.eq(words_of 'see https://example.com/x or example.org', {'see', 'or'}, 'URLs and domains')
    T.eq(words_of 'join #chan at 10pm, abc123 ok', {'join', 'at', 'ok'}, 'channels and digits')
    T.eq(words_of '\x0304,02red\x03 \x02bold\x02 \x04ff00ffhex', {'red', 'bold', 'hex'}, 'color parameters')
    T.eq(words_of '“quoted” — dash 🎉party', {'quoted', 'dash', 'party'}, 'punctuation and emoji')
    T.eq(words_of "'tis rock'n'roll", {'tis', "rock'n'roll"}, 'apostrophes at the edges')
end)

T.case('color parameters are read as the input line draws them', function()
    boot()
    -- ^D takes six hex digits or none, so these letters are text
    T.eq(words_of '\x04Becoming here', {'Becoming', 'here'}, 'fewer than six hex digits')
    T.eq(words_of '\x04face', {'face'}, 'hex letters only')
    T.eq(words_of '\x04ff0000,abc wrod', {'abc', 'wrod'}, 'a short background is text')
    T.eq(words_of '\x04ff0000,00ff00green', {'green'}, 'both colors')
    -- ^C takes one or two digits, and a background only after a foreground
    T.eq(words_of '\x03,5 \x031,22x', {'x'}, 'a comma without a foreground is text')
    -- each range is text as drawn: no control character or parameter in it
    local strip = T.require 'hub.lib.strip_formatting'
    for _, text in ipairs {'\x04Becoming', '\x0312,3abc\x04abcdefdef', '\x03,abc'} do
        local shown = strip(text)
        for _, w in ipairs(T.require 'hub.lib.words'(text)) do
            T.ok(shown:find(w.word, 1, true), w.word .. ' is shown in ' .. shown)
            T.ok(not w.word:find '%c', w.word .. ' has no controls')
        end
    end
end)

T.case('misspelled words, but for nicks and the word being typed', function()
    boot()
    local spell = T.require 'hub.runtime.spell'
    T.ok(spell.available(), 'dictionary opened')
    local function bad(text, is_nick, typing)
        local t = {}
        for _, w in ipairs(spell.misspelled(text, is_nick, typing)) do table.insert(t, w.word) end
        return t
    end
    local nicks = {alice = true, foo_bar = true, ['[xq]'] = true}
    local function is_nick(w) return nicks[w] or false end
    T.eq(bad 'the quikc brwon fox', {'quikc', 'brwon'}, 'misspelled')
    T.eq(bad('hello alice wrld', is_nick), {'wrld'}, 'a nick is a name')
    T.eq(bad("alice's wrld", is_nick), {'wrld'}, 'and so is its possessive')
    T.eq(bad('alice\u{2019}s wrld', is_nick), {'wrld'}, 'with a curly apostrophe')
    T.eq(bad('foo_bar: hi [xq], wrld', is_nick), {'hi', 'wrld'}, 'nicks with punctuation')
    T.eq(bad('hello wrld', nil, 11), {}, 'not while typing it')
    T.eq(bad('hello wrld', nil, 6), {'wrld'}, 'but once past it')
    T.eq(bad("hello isn'", nil, 11), {}, 'nor at an apostrophe in it')
    T.eq(bad('hello wrld', nil, 9), {}, 'nor while editing inside it')
    T.eq(spell.suggest 'brwon', {'brown'}, 'suggestions')
end)

T.case('talking underlines misspellings; commands do not', function()
    local c = boot()
    c:recv ':me!u@h JOIN #chan'
    T.require 'hub.ui.control'.set_view 'buffer'
    c:recv ':srv 353 me = #chan :@me alise foo_qux'
    key(string.byte 't')
    type_text "teh quick brwon alise's fxo foo_qux "
    local win = input_line()
    T.ok(win and fake_ncurses.row(win, 0):find('teh quick', 1, true), 'line drawn')
    T.eq(fake_ncurses.underlines(win, 0), {'teh', 'brwon', 'fxo'}, 'misspellings, not the members')
    type_text 'jmups'
    T.eq(fake_ncurses.underlines(input_line(), 0), {'teh', 'brwon', 'fxo'}, 'not the word being typed')
    key(0x1b)

    -- formatting underline goes on after a misspelling, and stops with ^_
    key(string.byte 't')
    -- typed, ^_ would be undo
    local control = T.require 'hub.ui.control'
    T.require 'hub.ui.editor'.insert(control.editor(), 'the \x1fbrwon fox\x1f teh')
    T.eq(fake_ncurses.underlines(input_line(), 0), {'␟brwon fox', 'teh'}, 'formatting and misspellings')
    key(0x1b)

    key(string.byte '/')
    type_text 'teh brwon '
    T.eq(fake_ncurses.underlines(input_line(), 0), {}, 'a command is not checked')
    key(0x1b)
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('Meta-$ cycles suggestions and undoes at once', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    control.set_view 'buffer'
    key(string.byte 't')
    type_text 'the brwon fox'
    key(0x1f & string.byte 'A')
    key(meta 'f')
    key(0x1f & string.byte 'F')
    key(0x1f & string.byte 'F') -- inside 'brwon'
    T.eq(control.editor().cursor, 6, 'cursor in the word')
    key(meta '$')
    T.eq(content(), 'the brown fox', 'first suggestion')
    T.eq(control.editor().cursor, 10, 'cursor after it')
    key(meta '$')
    T.eq(content(), 'the brwon fox', 'then the word as it was')
    key(meta '$')
    T.eq(content(), 'the brown fox', 'and round again')
    key(0x1f) -- C-_
    T.eq(content(), 'the brwon fox', 'one undo for the run')
    T.eq(control.editor().cursor, 6, 'back where the cursor was')

    key(0x1f & string.byte 'E')
    key(meta '$')
    T.eq(content(), 'the brown fox', 'after a correct word, the misspelling before it')
    key(0x1f & string.byte 'E')
    type_text ' qiuck'
    key(meta '$')
    T.eq(content(), 'the brown fox quick', 'the word just typed')
    key(0x1b)
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('Meta-$ replaces only the underlined word', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    control.set_view 'buffer'
    c:recv ':srv 353 me = #chan :@me brwon'
    HUB.current.routes['ui.draw']()
    local function fix(text)
        key(0x1f & string.byte 'E')
        key(0x1f & string.byte 'U')
        type_text(text)
        key(meta '$')
        return content()
    end
    key(string.byte 't')
    T.eq(fix 'the wrod—and', 'the word—and', 'up to a dash')
    T.eq(fix 'see wrod🎉', 'see word🎉', 'up to an emoji')
    T.eq(fix 'the “wrod”', 'the “word”', 'inside quotes')
    T.eq(fix 'café wrods', 'café words', 'after a multibyte word')
    T.eq(fix 'wrod2', 'wrod2', 'not a word with digits')
    T.eq(fix 'the brwon', 'the brwon', 'not a nick in the channel')
    T.eq(fix '', '', 'nothing on an empty line')
    key(0x1b)
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('/spell checks and adds words', function()
    local personal = os.tmpname()
    os.remove(personal)
    boot(personal)
    T.command 'spell brwon'
    T.eq(T.log_lines 'spell', {'brwon: brown'}, 'suggestions')
    T.command 'spell_add snowcone'
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.check 'snowcone', true, 'accepted at once')
    local f = assert(io.open(personal))
    T.eq(f:read 'a', 'snowcone\n', 'written to the personal list')
    f:close()

    -- a fresh boot reads the personal list
    boot(personal)
    T.eq(T.require 'hub.runtime.spell'.check 'snowcone', true, 'kept')
    os.remove(personal)
end)

T.case('without [spell] nothing is checked', function()
    local fake = FakeTransport.new()
    T.boot {ui = true, transport = fake, config = {networks = {}}}
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.available(), false, 'off')
    T.eq(spell.misspelled 'teh', {}, 'no misspellings')
    T.command 'spell teh'
    local errors = T.log_lines 'error'
    T.ok(errors[#errors] and errors[#errors]:find('not configured', 1, true), 'the command says so')
end)

T.case('a dictionary that fails to open is tried again by /reload', function()
    local base = os.tmpname()
    os.remove(base)
    local raw = {spell = {dictionary = base, personal = unused}, networks = {}}
    T.boot {ui = true, transport = FakeTransport.new(), config = raw}
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.available(), false, 'off')
    T.eq(spell.available(), false, 'still off')
    local errors = T.log_lines 'error'
    T.eq(#errors, 1, 'one error')
    T.eq(errors[1], 'spell: ' .. base .. '.aff: No such file or directory', 'naming the file, and only that')
    T.command 'spell teh'
    errors = T.log_lines 'error'
    T.ok(errors[#errors]:find('/reload tries again', 1, true), '/spell says why')

    -- the dictionary is installed
    for _, ext in ipairs {'.aff', '.dic'} do
        local from = assert(io.open(dictionary .. ext, 'rb'))
        local to = assert(io.open(base .. ext, 'wb'))
        to:write(from:read 'a')
        from:close()
        to:close()
    end
    T.ok(T.reload {config = raw}, 'reloaded')
    T.ok(T.require 'hub.runtime.spell'.available(), 'open after /reload')
    os.remove(base .. '.aff')
    os.remove(base .. '.dic')
end)

T.case('/spell_add takes effect for every form of the word', function()
    local personal = os.tmpname()
    -- a hand-edited list without a final line break, with a byte order mark
    local f = assert(io.open(personal, 'w'))
    f:write '\xef\xbb\xbfalpha'
    f:close()
    boot(personal)
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.check 'alpha', true, 'read without a line break or the mark')
    T.eq(spell.check 'Snowcone', false, 'judged first')
    T.command 'spell_add snowcone'
    T.eq(spell.check 'Snowcone', true, 'capitalized, after adding')
    T.command 'spell_add snowcone'
    f = assert(io.open(personal))
    T.eq(f:read 'a', '\xef\xbb\xbfalpha\nsnowcone\n', 'a line of its own, once')
    f:close()
    for _, word in ipairs {'bad\1word', 'foo,', 'abc1'} do
        T.command('spell_add ' .. word)
        local errors = T.log_lines 'error'
        T.ok(errors[#errors] and errors[#errors]:find('sees whole', 1, true), 'refused: ' .. word)
    end
    os.remove(personal)
end)

T.case('an unreadable personal list is logged, not raised', function()
    local where = os.tmpname()
    os.remove(where)
    assert(require 'pl.dir'.makepath(where))
    boot(where) -- a directory
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.available(), false, 'off')
    local errors = T.log_lines 'error'
    T.eq(#errors, 1, 'one error')
    T.ok(errors[1] and errors[1]:find(where, 1, true), 'naming the list')
    os.remove(where)
end)

T.case('each reload reopens the dictionary and closes the one before', function()
    local personal = os.tmpname()
    boot(personal)
    local resources = T.require 'hub.runtime.resources'
    local id = HUB.state.spell.id ---@type integer
    T.ok(resources.get(id), 'open at activation, held as a resource')
    T.eq(T.require 'hub.runtime.spell'.check 'qqqx', false, 'not a word yet')

    -- edited by hand, read again by /reload
    local f = assert(io.open(personal, 'a'))
    f:write 'qqqx\n'
    f:close()
    T.ok(T.reload(), 'reloaded')
    T.eq(resources.get(id), nil, 'the old handle closed')
    T.ok(HUB.state.spell.id and resources.get(HUB.state.spell.id), 'a new one open')
    T.eq(T.require 'hub.runtime.spell'.check 'qqqx', true, 'the edit is read')

    -- no [spell] closes it at once, without anything checking
    local id2 = HUB.state.spell.id ---@type integer
    T.ok(T.reload {config = {networks = {}}}, 'reloaded')
    T.eq(resources.get(id2), nil, 'closed')
    T.eq(HUB.state.spell.id, nil, 'and forgotten')
    os.remove(personal)
end)

T.case('formatting inside a word leaves it one word', function()
    boot()
    local spell = T.require 'hub.runtime.spell'
    local function check(text, words, ranges, what)
        local got = {}
        for _, w in ipairs(T.require 'hub.lib.words'(text)) do table.insert(got, w.word) end
        T.eq(got, words, what)
        local bad = {}
        for _, r in ipairs(spell.misspelled_ranges(text)) do table.insert(bad, text:sub(r.lo, r.hi)) end
        T.eq(bad, ranges, what .. ': misspelled bytes')
    end
    check('the \x02qui\x02ck fox', {'the', 'quick', 'fox'}, {}, 'bold')
    check('the \x0304qui\x03ck fox', {'the', 'quick', 'fox'}, {}, 'color')
    check('the \x02br\x1fwo\x0fn', {'the', 'brwon'}, {'br', 'wo', 'n'}, 'a misspelling in pieces')
    check('\x04ff0000qu\x04ick', {'quick'}, {}, 'hex color')
    -- Meta-$ replaces the whole of it, formatting and all
    local w = spell.pick('the \x02br\x02won', 13)
    T.eq(w and w.word, 'brwon', 'picked')
    T.eq(w and {w.lo, w.hi}, {6, 11}, 'from its first letter to its last, with the code between')
end)

T.case('the word before the cursor is judged; one being fixed is not', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    c:recv ':me!u@h JOIN #chan'
    control.set_view 'buffer'
    key(string.byte 't')
    editor.insert(control.editor(), 'fox teh')
    editor.move(control.editor(), 5) -- just before teh
    type_text 'dog '
    T.eq(content(), 'fox dog teh', 'typed before it')
    T.eq(fake_ncurses.underlines(input_line(), 0), {'teh'}, 'teh is still judged')
    key(0x1f & string.byte 'E')
    key(0x7f) -- backspace inside the word being fixed
    T.eq(fake_ncurses.underlines(input_line(), 0), {}, 'not while fixing it')
    key(0x1f & string.byte 'A')
    T.eq(fake_ncurses.underlines(input_line(), 0), {'te'}, 'judged once left')
    key(0x1b)
end)

T.case('/spell says why it can\'t check', function()
    -- built without hunspell
    local lib = myhunspell
    myhunspell = nil
    local ok, err = pcall(function()
        T.boot {ui = true, transport = FakeTransport.new(),
                config = {spell = {dictionary = dictionary}, networks = {}}}
        local errors = T.log_lines 'error'
        T.eq(errors, {'spell: snowcone was built without hunspell'}, 'logged at activation')
        T.command 'spell teh'
        errors = T.log_lines 'error'
        T.eq(errors[#errors], 'spell: snowcone was built without hunspell', '/spell says so')
    end)
    myhunspell = lib
    if not ok then error(err, 0) end

    -- a dictionary that isn't UTF-8 checks only ASCII words
    local base = os.tmpname()
    local aff = assert(io.open(base .. '.aff', 'w'))
    aff:write 'SET ISO8859-1\n'
    aff:close()
    local dic = assert(io.open(base .. '.dic', 'w'))
    dic:write '2\nthe\nfox\n'
    dic:close()
    T.boot {ui = true, transport = FakeTransport.new(),
            config = {spell = {dictionary = base, personal = unused}, networks = {}}}
    local spell = T.require 'hub.runtime.spell'
    T.eq(spell.checkable 'café', false, 'not a Latin-1 word in UTF-8')
    T.command 'spell café'
    T.eq(T.log_lines 'spell', {"café can't be checked with this dictionary"}, 'not called correct')
    T.command 'spell_add café'
    local errors = T.log_lines 'error'
    T.eq(errors[#errors], "spell_add: café can't be checked with this dictionary", 'nor added')
    T.eq(spell.misspelled 'the café teh', {T.require 'hub.lib.words' 'the café teh'[3]}, 'only ASCII words judged')
    for _, ext in ipairs {'', '.aff', '.dic'} do os.remove(base .. ext) end
end)

T.case('the binding refuses what is not a dictionary', function()
    local base = here .. '/fixtures/spell'
    T.raises('not a regular file', myhunspell.open, base .. '.aff', here .. '/fixtures')
    local empty = os.tmpname()
    T.raises('not a hunspell dictionary', myhunspell.open, base .. '.aff', empty)
    os.remove(empty)
    T.raises('No such file', myhunspell.open, base .. '.aff', base .. '.nope')
    local h <close> = myhunspell.open(base .. '.aff', base .. '.dic')
    T.raises('NUL', h.spell, h, 'wrod\0x')
    T.raises('NUL', h.add, h, 'wrod\0x')
    T.eq(h:suggest 'brwon', {'brown'}, 'suggestions')
    T.eq(h:encoding(), 'UTF-8', 'encoding')
end)

T.case('Tab between Meta-$ presses keeps the spellings', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    c:recv ':me!u@h JOIN #chan'
    control.set_view 'buffer'
    key(string.byte 't')
    type_text 'the brwon'
    key(meta '$')
    T.eq(content(), 'the brown', 'replaced')
    key(9) -- Tab, with nothing to complete
    T.eq(content(), 'the brown', 'nothing completed')
    key(meta '$')
    T.eq(content(), 'the brwon', 'the cycle goes on')
    key(0x1b)
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('Meta-$ leaves a word with formatting inside it alone', function()
    local c = boot()
    local control = T.require 'hub.ui.control'
    local editor = T.require 'hub.ui.editor'
    c:recv ':me!u@h JOIN #chan'
    control.set_view 'buffer'
    key(string.byte 't')
    editor.insert(control.editor(), 'the br\x02won fox')
    key(meta '$')
    T.eq(content(), 'the br\x02won fox', 'unchanged, bold and all')
    T.eq(T.log_lines 'spell', {'brwon has formatting inside it; fix it by hand'}, 'and says why')
    T.eq(fake_ncurses.underlines(input_line(), 0), {'br', 'won'}, 'still underlined')
    key(0x1b)
end)

-- Make a file unreadable for the length of f
local function unreadable(file, f)
    assert(os.execute(string.format('chmod 000 %q', file)))
    local ok, err = pcall(f)
    os.execute(string.format('chmod 644 %q', file))
    if not ok then error(err, 0) end
end

T.case('unreadable files are logged, not taken as empty', function()
    -- the dictionary's .aff
    local base = os.tmpname()
    for _, ext in ipairs {'.aff', '.dic'} do
        local from = assert(io.open(dictionary .. ext, 'rb'))
        local to = assert(io.open(base .. ext, 'wb'))
        to:write(from:read 'a')
        from:close()
        to:close()
    end
    unreadable(base .. '.aff', function()
        T.boot {ui = true, transport = FakeTransport.new(),
                config = {spell = {dictionary = base, personal = unused}, networks = {}}}
        T.eq(T.require 'hub.runtime.spell'.available(), false, 'off')
        T.eq(T.log_lines 'error', {'spell: ' .. base .. '.aff: Permission denied'}, 'the .aff')
    end)

    -- the personal list
    local personal = os.tmpname()
    local f = assert(io.open(personal, 'w'))
    f:write 'qqqx\n'
    f:close()
    unreadable(personal, function()
        boot(personal)
        T.eq(T.require 'hub.runtime.spell'.available(), false, 'off')
        T.eq(T.log_lines 'error', {'spell: ' .. personal .. ': Permission denied'}, 'the list')
    end)

    -- named with an extension, the dictionary opens
    T.boot {ui = true, transport = FakeTransport.new(),
            config = {spell = {dictionary = base .. '.dic', personal = personal}, networks = {}}}
    T.ok(T.require 'hub.runtime.spell'.available(), 'by its .dic')
    T.eq(T.require 'hub.runtime.spell'.check 'qqqx', true, 'and the list readable again')
    for _, file in ipairs {base, base .. '.aff', base .. '.dic', personal} do os.remove(file) end
end)

T.run()
