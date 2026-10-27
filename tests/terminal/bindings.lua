-- Calls every ncurses binding, with good arguments and bad, for
-- tests-terminal (sanitized builds catch what a wrong call does to memory).
-- Reports "fail <check>: <why>" on descriptor 3 for each check that fails,
-- then "done", and shuts down.

local here = arg[0]:match '^(.*)/[^/]*$' or '.'

local out = assert(io.open('/dev/fd/3', 'w'))
out:setvbuf 'line'

local current
local function fail(why)
    out:write('fail ', current, ': ', tostring(why):gsub('\n', ' '), '\n')
end

local function check(name, f)
    current = name
    local ok, err = pcall(f)
    if not ok then fail(err) end
end

local function raises(f, ...)
    local ok, err = pcall(f, ...)
    if ok then error('no error', 2) end
    return err
end

local function equal(a, b)
    if a ~= b then error(string.format('%s ~= %s', tostring(a), tostring(b)), 2) end
end

snowcone.start_ui()

check('the fake has the real names', function()
    local fake = dofile(here .. '/../hub/fake_ncurses.lua')
    local real = {functions = {}, constants = {}, methods = {}}
    for k, v in pairs(ncurses) do
        table.insert(type(v) == 'function' and real.functions or real.constants, k)
    end
    local win <close> = ncurses.newwin(1, 1, 0, 0)
    for k in pairs(getmetatable(win).__index) do table.insert(real.methods, k) end
    for _, kind in ipairs {'functions', 'constants', 'methods'} do
        table.sort(real[kind])
        local fakes = table.move(fake[kind], 1, #fake[kind], 1, {})
        table.sort(fakes)
        equal(table.concat(fakes, ' '), table.concat(real[kind], ' '))
    end
end)

check('the standard screen', function()
    ncurses.erase()
    ncurses.clear()
    ncurses.addstr('hello', ' ', 'world')
    equal(select(2, ncurses.getyx()), 11)
    local h, w = ncurses.getmaxyx()
    equal(h, tty_height)
    equal(w, tty_width)
    ncurses.move(1, 2)
    local y, x = ncurses.getyx()
    equal(y, 1)
    equal(x, 2)
    raises(ncurses.move, -1, 0)
    raises(ncurses.move, h, 0)
    ncurses.mvaddstr(2, 0, 'text')
    ncurses.mvaddstr(3, 0) -- moves only
    equal(ncurses.getyx(), 3)
    ncurses.noutrefresh()
    ncurses.doupdate()
    ncurses.refresh()
    ncurses.beep()
    ncurses.flash()
end)

check('mvaddstr outside the screen does nothing', function()
    ncurses.move(0, 0)
    ncurses.mvaddstr(-1, 0, 'x')
    ncurses.mvaddstr(0, tty_width, 'x')
    ncurses.mvaddstr(tty_height, 0, 'x')
    ncurses.mvaddstr(math.maxinteger, 0, 'x')
    ncurses.mvaddstr(1 << 32, 1 << 32, 'x') -- not 0, 0
    local y, x = ncurses.getyx()
    equal(y, 0)
    equal(x, 0)
end)

check('attributes and colors', function()
    ncurses.attron(ncurses.WA_BOLD)
    ncurses.attroff(ncurses.WA_BOLD)
    ncurses.attrset(ncurses.WA_REVERSE, 0)
    local attrs, pair = ncurses.attrget()
    equal(attrs & ncurses.WA_REVERSE, ncurses.WA_REVERSE)
    equal(pair, 0)
    for fore = -1, 7 do
        for back = -1, 7 do
            ncurses.colorset(fore, back)
        end
    end
    ncurses.colorset()
    raises(ncurses.colorset, 8)
    raises(ncurses.colorset, -2)
    raises(ncurses.colorset, 0, 8)
    raises(ncurses.colorset, math.mininteger)
    raises(ncurses.attrset, 0, 1 << 16) -- a color pair is a short
    ncurses.attrset(ncurses.WA_NORMAL, 0)
end)

check('cursor visibility', function()
    local before = ncurses.cursset(1)
    equal(ncurses.cursset(before), 1)
    raises(ncurses.cursset, 3)
    raises(ncurses.cursset, -1)
    raises(ncurses.cursset, (1 << 32) + 1) -- not 1
end)

check('windows', function()
    local win = ncurses.newwin(5, 10, 1, 1)
    win:waddstr('a long line that wraps and runs off the bottom of the window')
    win:waddstr('more', 'and more')
    win:wmove(4, 9)
    raises(win.wmove, win, 5, 0)
    raises(win.wmove, win, 0, -1)
    win:werase()
    win:wclear()
    win:wresize(3, 4)
    equal(select(1, ncurses.getmaxyx(win)), 3)
    ncurses.erase(win)
    ncurses.clear(win)
    ncurses.attron(ncurses.WA_BOLD, win)
    ncurses.colorset(1, -1, win)
    ncurses.noutrefresh(win)
    ncurses.refresh(win)
    ncurses.doupdate()
    win:delwin()
end)

check('pads', function()
    local pad = ncurses.newpad(100, 200)
    pad:waddstr(string.rep('x', 100 * 200 + 50))
    pad:pnoutrefresh(0, 0, 0, 0, 5, 5)
    pad:prefresh(90, 190, 0, 0, tty_height - 1, tty_width - 1)
    pad:pnoutrefresh(-1, -1, 0, 0, 5, 5) -- taken as 0, 0
    raises(pad.prefresh, pad, 0, 0, 0, 0, tty_height, tty_width + 1)
    raises(pad.prefresh, pad, 0, 0, 0, 0, 1 << 32, 1)
    pad:wresize(4096, 80)
    pad:delwin()
end)

check('bad sizes', function()
    raises(ncurses.newwin, -1, 10, 0, 0)
    raises(ncurses.newpad, 0, 0)
    raises(ncurses.newpad, -1, 10)
    raises(ncurses.newpad, (1 << 32) + 1, 10) -- not 1
    raises(ncurses.newwin, 1, 1, 1 << 32, 0) -- not 0
    local pad <close> = ncurses.newpad(1, 1)
    raises(pad.wresize, pad, 0, 0)
    raises(pad.wresize, pad, (1 << 32) + 1, 1)
    raises(pad.wmove, pad, 1 << 32, 0)
end)

check('a window after delwin', function()
    local win = ncurses.newwin(2, 2, 0, 0)
    win:delwin()
    win:delwin() -- again, harmlessly
    for _, call in ipairs {
        function() win:waddstr 'x' end,
        function() win:wmove(0, 0) end,
        function() win:werase() end,
        function() win:wclear() end,
        function() win:wresize(1, 1) end,
        function() win:pnoutrefresh(0, 0, 0, 0, 1, 1) end,
        function() win:prefresh(0, 0, 0, 0, 1, 1) end,
        function() ncurses.getyx(win) end,
        function() ncurses.getmaxyx(win) end,
        function() ncurses.erase(win) end,
        function() ncurses.refresh(win) end,
        function() ncurses.attron(0, win) end,
        function() ncurses.colorset(1, 1, win) end,
    } do
        local err = raises(call)
        if not tostring(err):find 'after delwin' then error(err) end
    end
end)

check('to-be-closed and collected windows', function()
    do
        local win <close> = ncurses.newwin(1, 1, 0, 0)
        win:waddstr 'x'
    end
    for _ = 1, 1000 do
        ncurses.newpad(10, 10)
    end
    collectgarbage()
    collectgarbage()
end)

check('wrong types', function()
    local win <close> = ncurses.newwin(1, 1, 0, 0)
    local methods = getmetatable(win).__index
    raises(ncurses.newwin, 'a', 1, 0, 0)
    raises(ncurses.newwin, 1.5, 1, 0, 0)
    raises(ncurses.getyx, 'stdscr')
    raises(ncurses.getyx, {})
    raises(ncurses.addstr, {})
    raises(ncurses.mvaddstr, 0, 0, {})
    raises(win.waddstr, win, {})
    raises(methods.waddstr, {}, 'x')
    raises(methods.waddstr, io.stdout, 'x')
    raises(methods.delwin, 'x')
    raises(ncurses.attron)
    raises(ncurses.cursset)
end)

check('strings with NUL', function()
    ncurses.addstr('a\0b')
    local win <close> = ncurses.newwin(1, 10, 0, 0)
    win:waddstr('a\0b')
end)

out:write 'done\n'
snowcone.shutdown()
