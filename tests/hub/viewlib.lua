-- Helpers for the UI's tests: a fake ncurses, a network to boot on, and
-- keys and text through the native entry point.
--
--   local V = dofile(here .. '/viewlib.lua')(T, here)

return function(T, here)
    local FakeTransport = dofile(here .. '/fake_transport.lua')
    local fake_ncurses = dofile(here .. '/fake_ncurses.lua')
    local path = require 'pl.path'

    fake_ncurses.install(150, 40)
    local ncurses = fake_ncurses.ncurses

    local function boot(buffers, hide, ircd)
        local fake = FakeTransport.new()
        T.boot {ui = true, transport = fake, config = {networks = {{
            id = 'test',
            ircd = ircd,
            server = {host = 'test.example', port = 6667},
            identity = {nick = 'me'},
            servers_file = path.abspath(here .. '/fixtures/servers.toml'),
            buffers = buffers,
            hide = hide,
        }}}}
        local c = fake.last()
        c:con()
        c:recv ':srv CAP * LS :'
        c:recv ':srv 001 me :Welcome'
        c:recv ':srv 005 me CHANTYPES=# MONITOR=100 :are supported'
        c:recv ':srv 376 me :End of MOTD'
        c:recv ':srv 221 me +o'
        return c
    end

    local function key(k)
        HUB.current.routes['ui.entry']('on_keyboard', k)
    end

    local function type_text(text)
        for _, c in utf8.codes(text) do key(c) end
    end

    -- The detail pane's pad, which a wide kind makes wider than the screen:
    -- the layout makes it just before the document pad, and the input line's
    -- one-row pad after
    local function detail_pad()
        local pads = {}
        for _, win in ipairs(fake_ncurses.windows) do
            if win.kind == 'newpad' and win.h > 1 then table.insert(pads, win) end
        end
        return pads[#pads - 1]
    end

    -- Rows of a window, from its top
    local function rows_of(win)
        local rows = {}
        for y = 0, win.y do rows[y] = fake_ncurses.row(win, y) end
        return rows
    end

    -- Whether a row, its trailing spaces dropped, matches a pattern
    local function has_row(rows, pattern)
        for y = 0, #rows do
            if rows[y]:match '^(.-)%s*$':find(pattern) then return true end
        end
        return false
    end

    -- The text of the status bar as last drawn
    local function status_bar()
        HUB.current.routes['ui.draw']()
        for i = #fake_ncurses.windows, 1, -1 do
            local win = fake_ncurses.windows[i]
            if win.kind == 'newwin' and win.h == 1 and win.w == tty_width then
                return fake_ncurses.row(win, 0)
            end
        end
    end

    -- The text of the detail pane as last drawn
    local function detail_text()
        HUB.current.routes['ui.draw']()
        local pad = detail_pad()
        local rows = {}
        for y = 0, pad.y do table.insert(rows, fake_ncurses.row(pad, y)) end
        return table.concat(rows, '\n')
    end

    return {
        FakeTransport = FakeTransport,
        fake_ncurses = fake_ncurses,
        path = path,
        ncurses = ncurses,
        boot = boot,
        key = key,
        type_text = type_text,
        detail_pad = detail_pad,
        rows_of = rows_of,
        has_row = has_row,
        status_bar = status_bar,
        detail_text = detail_text,
    }
end
