# myncurses

A simple Lua binding for ncurses, linked into snowcone and loaded as the
`ncurses` global by `snowcone.start_ui()`, after the terminal is set up.

```lua
local pad = ncurses.newpad(rows, cols)  -- also ncurses.newwin(rows, cols, y, x)
ncurses.colorset(ncurses.COLOR_RED, nil, pad)  -- nil colors are the defaults
ncurses.attron(ncurses.WA_BOLD, pad)
pad:waddstr('hello')
pad:pnoutrefresh(0, 0, 0, 0, tty_height - 1, tty_width - 1)
ncurses.doupdate()
pad:delwin()                            -- also on __close and __gc
```

Functions that take a window last use stdscr when it is nil or absent.
They raise when ncurses reports an error, except the `addstr` family,
which ignores errors so that text past a window's end is dropped. A
deleted window raises when used again; deleting it again does nothing.

Color pairs are made as `colorset` needs them, from a table of 200 per
screen row; past that, the least recently used pair is redefined.
