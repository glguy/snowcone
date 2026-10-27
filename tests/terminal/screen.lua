-- A small full-screen program for tests-terminal's screen tests. It draws
-- text, attributes, a color and wide characters, and its size on the last
-- row, and redraws on every resize. Keys:
--
--   s   stop input for 300 ms, as when a command has the terminal
--   z   suspend, as hub's ^Z does
--   ^D  shut down
--
-- Events on descriptor 3: ready, drawn <width> <height>, stopped, started

local out = assert(io.open('/dev/fd/3', 'w'))
out:setvbuf 'line'

local function emit(...)
    out:write(table.concat({...}, ' '), '\n')
end

local function draw()
    ncurses.erase()
    ncurses.mvaddstr(0, 0, 'hello')
    ncurses.attron(ncurses.WA_BOLD)
    ncurses.mvaddstr(1, 0, 'bold')
    ncurses.attroff(ncurses.WA_BOLD)
    ncurses.attron(ncurses.WA_REVERSE)
    ncurses.mvaddstr(1, 5, 'reverse')
    ncurses.attroff(ncurses.WA_REVERSE)
    ncurses.colorset(ncurses.COLOR_RED)
    ncurses.mvaddstr(1, 13, 'red')
    ncurses.colorset()
    ncurses.mvaddstr(2, 0, 'wide: é€😀漢字|')
    ncurses.mvaddstr(tty_height - 1, 0, string.format('bottom %dx%d', tty_width, tty_height))
    ncurses.refresh()
    emit('drawn', tty_width, tty_height)
end

local timer = snowcone.newtimer()

snowcone.setmodule(function(event, ...)
    if event == 'on_keyboard' then
        local key = ...
        if key == 4 then
            snowcone.shutdown()
        elseif key == string.byte 's' then
            snowcone.stop_input()
            emit 'stopped'
            timer:start(300, function()
                snowcone.start_input()
                draw()
                emit 'started'
            end)
        elseif key == string.byte 'z' then
            snowcone.raise(snowcone.SIGTSTP)
        end
    elseif event == 'on_resize' then
        draw()
    end
end)

snowcone.start_ui()
draw()
emit 'ready'
