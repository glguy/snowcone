// Lua binding for ncurses: windows, pads, attributes and colors

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

// Pushes the myncurses module table: the functions addstr, mvaddstr, getyx,
// getmaxyx, refresh, noutrefresh, erase, clear, attron, attroff, attrset,
// attrget, colorset, cursset, move, beep, flash, newwin, newpad and
// doupdate, and the integer constants COLOR_* (with COLOR_DEFAULT, -1),
// COLORS, WA_* and KEY_* (with KEY_F1 to KEY_F12). Call after initscr and
// start_color, as COLORS is read once here; registers the WINDOW metatable
// when the first window is made.
int luaopen_myncurses(struct lua_State* L);

// Sets the globals tty_width and tty_height to stdscr's size, which can run
// a __newindex metamethod on the globals table.
void l_ncurses_resize(struct lua_State* L);

#ifdef __cplusplus
}
#endif
