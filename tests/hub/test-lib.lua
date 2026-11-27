-- hub's library modules on their own.
--
-- Run with:  snowcone tests/hub/test-lib.lua

-- A test reads what it expects to be there, and a nil fails it
---@diagnostic disable: need-check-nil

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

local function ordered_map(max)
    T.boot {}
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    return OrderedMap, OrderedMap.new(max)
end

local function collect(iter)
    local t = {}
    for v in iter do table.insert(t, v) end
    return t
end

T.case('Lua patterns are checked through to their end', function()
    T.boot {}
    local check = T.require 'hub.lib.luapattern'.check
    for _, good in ipairs {
        '', '^KLINE:EXPIRE:', 'a$', 'a$b', '[]]', '[^]]', '[%]]', '%f[%w]me%f[^%w]',
        '%bxy', '(a)%1', '()', '(a(b)%2)', '[a-z]+%d*', '*a', '^g[:,]', '%%', 'a-', '[%a_][%w_]*',
    } do
        T.eq(check(good), nil, good)
        T.ok(pcall(string.find, 'some text', good), 'Lua agrees: ' .. good)
    end
    for pattern, err in pairs {
        ['a['] = "missing ']'", ['x('] = 'unfinished capture', ['foo%'] = "ends with '%'",
        ['a%b'] = 'missing arguments to %b', ['a%bx'] = 'missing arguments to %b',
        ['a%f'] = "missing '['", ['a%fx'] = "missing '['", ['b[%'] = "missing ']'",
        ['a)'] = 'invalid pattern capture', ['a%1'] = 'invalid capture index %1',
        ['(a%1)'] = 'invalid capture index %1', ['a%0'] = 'invalid capture index %0',
        ['[a'] = "missing ']'", ['a%f[x'] = "missing ']'",
        [string.rep('()', 33)] = 'too many captures',
    } do
        local got = check(pattern)
        T.ok(got and got:find(err, 1, true), pattern .. ': ' .. tostring(got))
    end

    -- whatever passes, Lua matches without raising
    local alphabet = {'a', 'b', '(', ')', '[', ']', '%', '^', '$', '*', '+', '-', '?', '.', 'f', '1', '2'}
    local seed = 12345
    local function random(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n + 1
    end
    local subjects = {'', 'a', 'ab', 'ba', 'aab(b)', 'a[b]a', '%a%', 'aaaa bbbb', '()[]%^$*+-?.f12'}
    for _ = 1, 20000 do
        local parts = {}
        for _ = 1, random(8) do table.insert(parts, alphabet[random(#alphabet)]) end
        local pattern = table.concat(parts)
        if check(pattern) == nil then
            for _, subject in ipairs(subjects) do
                local ok, err = pcall(string.find, subject, pattern)
                T.ok(ok, ('accepted %q raises on %q: %s'):format(pattern, subject, tostring(err)))
            end
        end
    end
end)

T.case('OrderedMap numbers entries and drops the oldest', function()
    local OrderedMap, om = ordered_map(3)
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {1, 0, 0}, 'empty')
    T.eq(OrderedMap.get_oldest(om), nil, 'no oldest')
    for _, v in ipairs {'a', 'b', 'c', 'd', 'e'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {3, 5, 3}, 'holds 3 to 5')
    T.eq({OrderedMap.get(om, 2), OrderedMap.get(om, 3), OrderedMap.get(om, 6)}, {nil, 'c', nil}, 'by number')
    T.eq(OrderedMap.get_oldest(om), 'c', 'oldest')
    T.eq(collect(OrderedMap.each(om)), {'e', 'd', 'c'}, 'newest first')
    T.eq(collect(OrderedMap.each(om, 1)), {'d', 'c'}, 'skipping the newest')
    T.eq(collect(OrderedMap.reveach(om)), {'c', 'd', 'e'}, 'oldest first')
    T.eq({OrderedMap.lookup(om, 'b'), OrderedMap.lookup(om, 'c')}, {nil, 'c'}, 'dropped keys forgotten')
    T.eq({OrderedMap.number(om, 'b'), OrderedMap.number(om, 'c'), OrderedMap.number(om, 'e')}, {nil, 3, 5},
        'numbers by key')
    for _, v in ipairs {'f', 'g'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.number(om, 'e'), OrderedMap.number(om, 'g')}, {5, 7}, 'across the wrap')
end)

T.case('OrderedMap pops the newest, even after wrapping', function()
    local OrderedMap, om = ordered_map(3)
    for _, v in ipairs {'a', 'b', 'c', 'd'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.pop(om)}, {'d', 'd'}, 'val and key')
    T.eq(OrderedMap.lookup(om, 'd'), nil, 'key forgotten')
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {2, 3, 2}, 'b and c left')
    T.eq(collect(OrderedMap.reveach(om)), {'b', 'c'}, 'no hole where d was')
    OrderedMap.insert(om, 'x', 'x')
    T.eq({OrderedMap.get(om, 4), OrderedMap.get_oldest(om)}, {'x', 'b'}, 'its number reused; b kept')
    OrderedMap.pop(om)
    OrderedMap.pop(om)
    OrderedMap.pop(om)
    T.eq({OrderedMap.size(om), OrderedMap.pop(om)}, {0}, 'empty, and popping more does nothing')
    T.eq(collect(OrderedMap.each(om)), {}, 'nothing to iterate')
    OrderedMap.insert(om, 'y', 'y')
    T.eq({OrderedMap.first(om), OrderedMap.last(om)}, {2, 2}, 'numbering goes on')
    OrderedMap.reset(om)
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {1, 0, 0}, 'reset')
end)

T.case('command specs fit the whole line, word by word', function()
    T.boot {}
    local mkcommand = T.require 'hub.lib.mkcommand'
    local function parse(spec, args)
        local params = {}
        if mkcommand(spec)(args, params) then return params end
        return false
    end
    T.eq(parse('$g $r', 'alice'), false, 'a word with no text is a usage error')
    T.eq(parse('$g $r', '#chan'), false, 'and never splits the word')
    T.eq(parse('$g $r', 'alice hi there '), {'alice', 'hi there '}, 'the rest as typed')
    T.eq(parse('$g $R', 'alice'), {'alice', ''}, 'an empty rest')
    T.eq(parse('$g', 'a b'), false, 'a word left over')
    T.eq(parse('$g', ' a  '), {'a'}, 'spaces around')
    T.eq(parse('$g $r', '#voilà hi'), {'#voilà', 'hi'}, 'UTF-8 whole')
    T.eq(parse('$g $g', 'a  b'), {'a', 'b'}, 'more than one space between')
    T.eq(parse('$i', '42'), {42}, 'an integer')
    T.eq(parse('$i', '-3'), {-3}, 'signed')
    T.eq(parse('$i', '0x10'), false, 'not hex')
    T.eq(parse('$i', '99999999999999999999'), false, 'not too big')
    T.eq(parse('$f', '1.5e3'), {1500.0}, 'a number')
    T.eq(parse('$v', 'a_1'), {'a_1'}, 'an identifier')
    T.eq(parse('$v', '1a'), false, 'not starting with a digit')
    T.eq(parse('$q $g', '"two words" x'), {'two words', 'x'}, 'a quoted string')
    T.eq(parse('$q', [['mixed"]]), false, 'the same quote closes it')
    T.eq(parse('add $g', 'add x'), {'x'}, 'a literal word')
    T.eq(parse('add $g', 'del x'), false, 'that must match')
    T.eq(parse('$g $t', 'alice \x02hi\x02 there'), {'alice', '\x02hi\x02 there'}, 'text as the rest')
    T.eq(parse('$g $t', 'alice'), false, 'not empty')
    T.eq(parse('$g $T', 'alice'), {'alice', ''}, 'or possibly empty')
    T.ok(not pcall(mkcommand, '$t $g'), 'text last only')
    T.eq(parse('', ''), {}, 'no arguments')
    T.eq(parse('', 'x'), false, 'none given')
    T.ok(not pcall(mkcommand, '$r $g'), 'rest before the end refused')
    T.ok(not pcall(mkcommand, '$z'), 'an unknown type refused')
end)

T.case('command specs tell what each part of a line being typed is', function()
    T.boot {}
    local mkcommand = T.require 'hub.lib.mkcommand'
    local function analyze(spec, args)
        local a = select(2, mkcommand(spec))(args)
        local words = {}
        for i, w in ipairs(a.words) do
            words[i] = {args:sub(w.lo, w.hi), w.ok}
        end
        return {words = words, ok = a.ok,
                leftover = a.leftover and args:sub(a.leftover.lo, a.leftover.hi)}
    end

    T.eq(analyze('$g $r', ''), {words = {}, ok = false}, 'nothing typed: every item missing')
    T.eq(analyze('$g $r', 'alice '), {words = {{'alice', true}}, ok = false},
        'a word, the text still missing')
    T.eq(analyze('$g $r', '  alice  hi there '), {words = {{'alice', true}, {'hi there ', true}}, ok = true},
        'the rest as typed, spaces and all')
    T.eq(analyze('$g $R', 'alice'), {words = {{'alice', true}}, ok = true},
        'an empty rest has no word')
    T.eq(analyze('$i $g', 'x y'), {words = {{'x', false}, {'y', true}}, ok = false},
        'a word that does not fit, and the next one after it')
    T.eq(analyze('$g', 'a b  c '), {words = {{'a', true}}, ok = false, leftover = 'b  c'},
        'what is left over, as one stretch without its trailing space')
    T.eq(analyze('add $g', 'del x'), {words = {{'del', false}, {'x', true}}, ok = false},
        'a literal that does not match')
    T.eq(analyze('$q $g', '"two words" x'), {words = {{'"two words"', true}, {'x', true}}, ok = true},
        'a quoted string, quotes included')
    T.eq(analyze('$q $g', '"still typing'), {words = {{'"still typing', false}}, ok = false},
        'an open quote runs to the end')
    T.eq(analyze('$q $g', '"a"b c'), {words = {{'"a"b', false}, {'c', true}}, ok = false},
        'a quote closed inside a word')
    T.eq(analyze('$q', 'bare'), {words = {{'bare', false}}, ok = false}, 'no quotes')

    local a = select(2, mkcommand('$g $i'))('a 7')
    T.eq(a.params, {'a', 7}, 'the values, when it fits')
    T.eq(a.items, {{kind = 'g'}, {kind = 'i'}}, 'and the items, for what is missing')
    T.eq(select(2, mkcommand('$g $T'))('').items[2], {kind = 'T', rest = true, optional = true, text = true},
        'message text, marked so')
    T.eq(select(2, mkcommand('$r'))('').items[1], {kind = 'r', rest = true}, 'and the rest not')
end)

T.case('a usage is the placeholders of its words', function()
    T.boot {}
    local usage = T.require 'hub.lib.usage'
    local function labels(text)
        local ps, err = usage.parse(text)
        if not ps then return err end
        local t = {}
        for i, p in ipairs(ps) do
            t[i] = (p.optional and '?' or '') .. p.label .. (p.repeats and '*' or '')
        end
        return t
    end
    T.eq(labels(nil), {}, 'no usage, no placeholders')
    T.eq(usage.parse '[@tags] command'[1].sign, '@', 'an optional word starting with a sign')
    T.eq(usage.parse "['pattern'] [x]"[1].sign, nil, 'not a quote')
    T.eq(usage.parse '@nick'[1].sign, nil, 'nor a required word')
    T.eq(labels 'target text', {'target', 'text'}, 'a word each')
    T.eq(labels 'nick [reason]', {'nick', '?reason'}, 'optional in brackets')
    T.eq(labels '[nick...]', {'?nick*'}, 'repeating')
    T.eq(labels '[modes [arg...]]', {'?modes', '?arg*'}, 'brackets around brackets')
    T.eq(labels '[a b] c', {'?a', '?b', 'c'}, 'brackets around words')
    T.eq(labels 'name address[/prefix]', {'name', 'address[/prefix]'}, 'brackets inside a word')
    T.eq(labels '[nick!]user@host [realname]', {'[nick!]user@host', '?realname'}, 'opening a word')
    T.eq(labels "[n] 'pattern'|filter [no]beep", {'?n', "'pattern'|filter", '[no]beep'}, 'and alone')
    T.eq(labels 'dashboard|chat|all', {'dashboard|chat|all'}, 'choices are one word')
    T.eq(labels '[[no]beep]', {'?[no]beep'}, 'optional, with brackets of its own')
    T.eq(usage.parse '[[no]beep] word'[1].sign, nil, 'a bracket is no sign')
    T.eq(usage.parse '[-full|-v4|nick]'[1].sign, nil, 'nor one that not every choice starts with')
    T.eq(usage.parse '[-a|-b] x'[1].sign, '-', 'but one that every choice does')
    T.ok(labels 'a [b' :find('unmatched [', 1, true), 'an open bracket')
    T.ok(labels 'a b]' :find('unmatched ]', 1, true), 'a stray close')
    T.ok(labels 'x[a b]y' :find('span a space', 1, true), 'a word with a space in its brackets')
end)

T.case('placeholders line up with a spec and follow what is typed', function()
    T.boot {}
    local mkcommand = T.require 'hub.lib.mkcommand'
    local usage = T.require 'hub.lib.usage'
    local function check(spec, text, dynamic)
        local _, analyze = mkcommand(spec)
        return usage.check(analyze('').items, assert(usage.parse(text)), dynamic)
    end
    T.eq(check('$g $r', 'target text'), nil, 'one each')
    T.eq(check('', nil), nil, 'none')
    T.eq(check('$r', '[@tags] command [arguments]'), nil, 'a rest takes several; a sign before required')
    T.eq(check('$R', '[modes [arg...]]'), nil, 'all optional')
    T.ok(check('$g', 'a b'):find 'more words', 'too many')
    T.ok(check('$g $g', 'a'):find 'fewer words', 'too few')
    T.ok(check('$R', nil):find 'nothing for the rest', 'a rest with none')
    T.ok(check('$g $R', 'nick reason'):find 'shown as required', 'an empty rest must look optional')
    T.ok(check('$g', '[nick]'):find 'shown as optional', 'and a word required')
    T.ok(check('add $g', 'del word'):find 'the word add', 'a literal as itself')
    T.ok(check('$R', '[nick...] [x]'):find 'repeating argument before', 'repeats last only')
    T.ok(check('$R', '[add] word'):find 'optional argument before a required', 'out of order')
    T.eq(check('$R', '[add] word', true), nil, 'unless the command places them itself')

    local function pending(spec, text, args)
        local _, analyze = mkcommand(spec)
        local a = analyze(args)
        local slots = assert(usage.align(a.items, assert(usage.parse(text))))
        local t = {}
        for i, p in ipairs(usage.pending(slots, a, args)) do t[i] = p.label end
        return t
    end
    T.eq(pending('$g $r', 'target text', ''), {'target', 'text'}, 'nothing typed')
    T.eq(pending('$g $r', 'target text', 'bo'), {'text'}, 'a word being typed fills its place')
    T.eq(pending('$g $r', 'target text', 'bob hi there'), {}, 'the text takes many words')
    T.eq(pending('$i $g', 'n word', 'x'), {'word'}, 'a word that does not fit still fills its place')
    T.eq(pending('$g', 'nick', 'a b'), {}, 'nothing past what is left over')
    T.eq(pending('$g $R', 'nick [reason]', 'bob'), {'reason'}, 'an empty rest')
    T.eq(pending('$R', '[nick...]', 'a b'), {'nick'}, 'a repeating one stays')
    T.eq(pending('$r', 'command [arguments]', 'PRIVMSG'), {'arguments'}, 'words in the rest')
    T.eq(pending('$r', 'command [arguments]', 'PRIVMSG #c :hi'), {}, 'the last takes the remainder')
    local quote = '[@tags] command [arguments]'
    T.eq(pending('$r', quote, ''), {'@tags', 'command', 'arguments'}, 'all, before any word')
    T.eq(pending('$r', quote, 'PRIVMSG '), {'arguments'}, 'a word without the sign passes it by')
    T.eq(pending('$r', quote, '@a=b '), {'command', 'arguments'}, 'one with the sign takes it')
    T.eq(pending('$r', quote, '@a=b PRIVMSG'), {'arguments'}, 'and the next word the next')
end)

T.case('every command usage lines up with its spec', function()
    T.boot {}
    local usage = T.require 'hub.lib.usage'
    local bad = {}
    for name, cmd in pairs(HUB.current.commands) do
        local placeholders, err = usage.parse(cmd.usage)
        local items = cmd.analyze('').items
        ---@diagnostic disable-next-line: param-type-mismatch
        err = err or usage.check(items, placeholders, cmd.shape ~= nil)
        if cmd.shape and not (items[#items] and items[#items].rest) then
            err = 'a shape for a spec without a rest of the line'
        end
        if err then bad[name] = err end
    end
    T.eq(bad, {}, 'usages')
    T.eq(T.log_lines 'commands', {}, 'none takes its placeholders from its spec')
end)

T.case('a failed oneOf alternative leaves later errors their own path', function()
    T.boot {}
    local schema = T.require 'hub.lib.schema'
    local s = {type = 'table', fields = {
        a = {oneOf = {{type = 'table', fields = {x = {type = 'string'}}}, {type = 'table'}}},
        z = {type = 'string'},
    }}
    local ok, err = pcall(schema.check, s, {a = {y = 1}, z = 3}, {'root'})
    ---@diagnostic disable-next-line: undefined-field
    T.ok(not ok and err:find('in root.z ', 1, true), err)
end)

T.case('prefilter strings take backslash escapes', function()
    T.boot {}
    local matchdsl = T.require 'hub.lib.matchdsl'
    T.ok(matchdsl [[gecos 'it\'s']] {gecos = "it's"}, 'an escaped quote')
    T.ok(matchdsl [[gecos 'a\\']] {gecos = 'a\\'}, 'a value ending in a backslash')
    T.ok(not matchdsl [[gecos 'it\'s']] {gecos = "it\\'s"}, 'not the backslash itself')
end)

T.case('prefilter queries: and binds tighter than or; not and parentheses', function()
    T.boot()
    local q = T.require 'hub.lib.matchdsl'
    local function hits(query, entries)
        local p, names = q(query), {}
        for _, e in ipairs(entries) do
            if p(e) then table.insert(names, e.nick) end
        end
        return names
    end
    local entries = {
        {nick = 'a', user = 'u'}, {nick = 'b', user = 'u'}, {nick = 'b', user = 'v'}, {nick = 'c'},
    }
    T.eq(hits([[nick 'a' or nick 'b' and user 'u']], entries), {'a', 'b'}, 'a, or b with u')
    T.eq(hits([[(nick 'a' or nick 'b') and user 'u']], entries), {'a', 'b'}, 'grouped')
    T.eq(hits([[(nick 'a' or nick 'c') and not user 'u']], entries), {'c'}, 'not')
    T.eq(hits([[not not nick 'c']], entries), {'c'}, 'not of not')
    T.eq(hits([[nick 'a' or nick 'b' or nick 'c']], entries), {'a', 'b', 'b', 'c'}, 'a chain of or')
    T.eq(hits([[user '']], entries), {'c'}, 'a missing field is empty')
end)

T.case('prefilter regexes are extended PCRE2, and I ignores case', function()
    T.boot()
    local q = T.require 'hub.lib.matchdsl'
    if not pcall(require, 'rex_pcre2') then
        T.raises('got bad regex (regular expressions need rex_pcre2) expected a pattern', q, 'gecos |x|')
        return
    end
    T.ok(q [[gecos |^bot \d+$|]] {gecos = 'bot42'}, 'extended: a space in the pattern is ignored')
    T.ok(not q [[gecos |^bot \d+$|]] {gecos = 'bot 42'}, 'so it matches no space')
    T.ok(not q [[gecos |^bot\ \d+$|]] {gecos = 'BOT 42'}, 'case counts')
    T.ok(q [[gecos |^bot\ \d+$|I]] {gecos = 'BOT 42'}, 'unless I')
    T.ok(q [[ip |^192\.0\.2\.| and not host |example|]] {ip = '192.0.2.7', host = 'h.test'}, 'in a query')
end)

T.case('a prefilter query that does not parse says what it expected', function()
    T.boot()
    local q = T.require 'hub.lib.matchdsl'
    T.raises('got `end-of-input` expected a pattern', q, 'nick')
    T.raises('got bogus expected a pattern', q, [[bogus 'x']])
    T.raises('got `end-of-input` expected `)`', q, [[(nick 'a']])
    T.raises('got nick expected `end-of-input`', q, [[nick 'a' nick 'b']])
    T.raises('got bad regex (', q, 'nick |(|')
    T.raises('got `)` expected `end-of-input`', q, [[nick 'a' )]])
    T.raises('got `)` expected a pattern', q, '()')
    T.raises('got `#` expected a pattern', q, [[# nick 'a']])
    T.raises('got `string` expected `end-of-input`', q, [[nick 'a' 'b']])
end)

T.case('ratelimit allows a burst, then one line per interval', function()
    T.boot {}
    local ratelimit = T.require 'hub.lib.ratelimit'
    local burst, interval = 3, 2
    local t, now = 0, 100
    local waits = {}
    for _ = 1, 4 do
        table.insert(waits, ratelimit.wait(t, now, burst, interval))
        t = ratelimit.take(t, now, interval)
    end
    T.eq(waits, {0, 0, 0, 2}, 'three at once, the fourth waits an interval')
    T.eq(ratelimit.wait(t, now + 2, burst, interval), 2, 'the fifth an interval later')
    T.eq(ratelimit.wait(t, now + 4, burst, interval), 0, 'and may go then')
    T.eq(ratelimit.take(t, now + 100, interval), now + 102, 'idle time refills the burst, no further')
end)

T.run()
