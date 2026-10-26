-- Strings handed to C APIs reject embedded NULs instead of being truncated
-- at them, and binary-safe arguments keep every byte.
-- Run with:  snowcone script tests/test-strings.lua

local function rejects(what, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, what .. ' accepted a NUL')
    assert(err:find('NUL', 1, true), what .. ': ' .. tostring(err))
end

local noop = function() end

rejects('pton', snowcone.pton, '127.0.0.1\0junk')
assert(snowcone.pton '127.0.0.1' == '\127\0\0\1')

rejects('parse_irc', snowcone.parse_irc, 'PRIVMSG #a :x\0y')
rejects('parse_irc_tags', snowcone.parse_irc_tags, 'a=b\0c')
assert(snowcone.parse_irc('PRIVMSG #a :x').command == 'PRIVMSG')

rejects('dnslookup', snowcone.dnslookup, 'localhost\0junk', noop)
rejects('start_httpd host', snowcone.start_httpd, '127.0.0.1\0x', '0', noop)
rejects('start_httpd service', snowcone.start_httpd, '127.0.0.1', '0\0x', noop)
rejects('execute file', snowcone.execute, 'true\0x', {}, noop)
rejects('execute argument', snowcone.execute, 'echo', {'a\0b'}, noop)
rejects('connect host', snowcone.connect, 'irc.example\0x', 6667, {}, noop)

-- stdin is binary-safe: cat returns every byte
snowcone.execute('cat', {}, function(code, out)
    assert(code == 0, 'cat failed')
    assert(out == 'a\0b', 'stdin lost bytes: ' .. ('%q'):format(out))
    print 'ok'
end, {input = 'a\0b'})
