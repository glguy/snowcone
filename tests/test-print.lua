-- print without a UI writes its arguments to stdout, tab-separated, as the
-- standard print does, including print() with no arguments.
-- Run with:  snowcone tests/test-print.lua

local child = os.tmpname()
local f = assert(io.open(child, 'w'))
f:write [[print() print('a', 1, nil, true) print('x')]]
f:close()

-- arg[-1] is the snowcone binary running this test
snowcone.execute(arg[-1], {child}, function(code, out, err)
    os.remove(child)
    assert(code == 0, ('child failed (%s): %s'):format(code, err))
    local expected = '\na\t1\tnil\ttrue\nx\n'
    assert(out == expected, ('stdout: %q'):format(out))
    print 'ok'
end, {input = ''})
