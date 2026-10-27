-- An error message reaches the terminal escaped: it may quote a server's
-- line, and control sequences in it must not reach the terminal. Both a
-- runtime error and a file that fails to load end with a failure status.
-- Run with:  snowcone tests/test-escape.lua

-- Run a child script, then check its exit status and stderr
local function run(source, expected, next_step)
    local child = os.tmpname()
    local f = assert(io.open(child, 'w'))
    f:write(source)
    f:close()

    -- arg[-1] is the snowcone binary running this test
    snowcone.execute(arg[-1], {child}, function(code, _, err)
        os.remove(child)
        assert(code ~= 0, 'child script succeeded: ' .. source)
        assert(err:find(expected, 1, true), ('stderr: %q'):format(err))
        assert(not err:find('\27', 1, true), 'raw ESC on stderr')
        if next_step then next_step() end
    end, {input = ''})
end

-- ESC (an OSC title), BEL, a C1 CSI as UTF-8, an invalid byte; then text
-- that passes: UTF-8, a tab and a newline
run([[error('A\27]0;x\7B\xc2\x9bC\xffD é\tE\nF', 0)]],
    'error in reload: A\\x1b]0;x\\x07B\\xc2\\x9bC\\xffD é\tE\nF',
    function()
        -- a file that doesn't compile: the syntax error quotes the
        -- string that a newline left unfinished, ESC and all
        run('x = "\27]0;y\nz = 1\n', 'unfinished string near \'"\\x1b]0;y\'', function()
            print 'ok'
        end)
    end)
