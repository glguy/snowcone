-- hub's library modules on their own.
--
-- Run with:  snowcone tests/hub/test-lib.lua

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
    T.eq(parse('', ''), {}, 'no arguments')
    T.eq(parse('', 'x'), false, 'none given')
    T.ok(not pcall(mkcommand, '$r $g'), 'rest before the end refused')
    T.ok(not pcall(mkcommand, '$z'), 'an unknown type refused')
end)

T.case('a failed oneOf alternative leaves later errors their own path', function()
    T.boot {}
    local schema = T.require 'hub.lib.schema'
    local s = {type = 'table', fields = {
        a = {oneOf = {{type = 'table', fields = {x = {type = 'string'}}}, {type = 'table'}}},
        z = {type = 'string'},
    }}
    local ok, err = pcall(schema.check, s, {a = {y = 1}, z = 3}, {'root'})
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
