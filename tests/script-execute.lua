-- snowcone.execute with stdin that can't be polled, run as:
-- snowcone FILE </dev/null
-- On Linux every fork re-registers the client's descriptors with epoll,
-- which refuses /dev/null; the child must still exec, not carry on as a
-- second client.

snowcone.execute('echo', {'hello'}, function(code, out, err)
    assert(code == 0, 'echo failed: ' .. tostring(out))
    assert(out == 'hello\n', string.format('expected echo output, got %q', out))
    assert(err == '', string.format('unexpected stderr %q', err))
    print('ok  execute with stdin from /dev/null')
end)
