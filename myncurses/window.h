// WINDOW userdata for the ncurses binding: argument checks shared with
// myncurses.c, and newwin and newpad, which make windows.

#ifndef MYNCURSES_WINDOW_H
#define MYNCURSES_WINDOW_H

#include <ncurses.h>

struct lua_State;

/**
 * @brief Match a WINDOW argument, raising an argument error when it isn't
 * a window or the window has been deleted (delwin, __close or __gc)
 *
 * @param L Lua state
 * @param arg Stack index
 * @return Pointer to live WINDOW
 */
WINDOW* checkwindow(struct lua_State* L, int arg);

/**
 * @brief Match an optional WINDOW argument, as checkwindow does
 *
 * @param L Lua state
 * @param arg Stack index
 * @return Pointer to live WINDOW; stdscr when the argument is nil or absent
 */
WINDOW* optwindow(struct lua_State*, int arg);

/**
 * @brief Match an integer argument that fits an int, as ncurses takes it;
 * a larger one raises an argument error rather than wrap to some other value
 *
 * @param L Lua state
 * @param arg Stack index
 * @return The argument
 */
int checkint(struct lua_State* L, int arg);

/**
 * @brief Lua: newwin(lines, columns, y, x) -> window. A new window of that
 * size at that screen position; raises "newwin: ncurses error" on failure.
 */
int l_newwin(struct lua_State*);

/**
 * @brief Lua: newpad(lines, columns) -> window. A new pad of that size,
 * shown with prefresh or pnoutrefresh; raises "newpad: ncurses error" on
 * failure.
 */
int l_newpad(struct lua_State*);

#endif
