#ifndef MYNCURSES_WINDOW_H
#define MYNCURSES_WINDOW_H

#include <ncurses.h>

struct lua_State;

WINDOW* checkwindow(struct lua_State*, int arg);
WINDOW* optwindow(struct lua_State*, int arg);
int l_newwin(struct lua_State*);
int l_newpad(struct lua_State*);

#endif
