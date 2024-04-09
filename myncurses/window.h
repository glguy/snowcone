#ifndef MYNCURSES_WINDOW_H
#define MYNCURSES_WINDOW_H

#include <ncurses.h>

struct lua_State;

/**
 * @brief Match a WINDOW argument
 * 
 * @param L Lua state
 * @param arg Stack index
 * @return Pointer to live WINDOW
 */
WINDOW* checkwindow(struct lua_State* L, int arg);

/**
 * @brief Match an optional WINDOW argument
 * 
 * @param L Lua state
 * @param arg Stack index
 * @return Pointer to live WINDOW defaults to stdsrc
 */
WINDOW* optwindow(struct lua_State*, int arg);

int l_newwin(struct lua_State*);

int l_newpad(struct lua_State*);

#endif
