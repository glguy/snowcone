-- An error message reaches the terminal escaped: it may quote a server's
-- line, and control sequences in it must not reach the terminal.
-- Run with:  snowcone tests/test-escape.lua

local child = os.tmpname()
local f = assert(io.open(child, 'w'))
-- ESC (an OSC title), BEL, a C1 CSI as UTF-8, an invalid byte; then text
-- that passes: UTF-8, a tab and a newline
f:write [[error('A\27]0;x\7B\xc2\x9bC\xffD é\tE\nF', 0)]]
f:close()

-- arg[-1] is the snowcone binary running this test
snowcone.execute(arg[-1], {child}, function(code, _, err)
    os.remove(child)
    assert(code ~= 0, 'child script succeeded')
    local expected = 'error in reload: A\\x1b]0;x\\x07B\\xc2\\x9bC\\xffD é\tE\nF'
    assert(err:find(expected, 1, true), ('stderr: %q'):format(err))
    assert(not err:find('\27', 1, true), 'raw ESC on stderr')
    print 'ok'
end, {input = ''})
