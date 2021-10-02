
#ifndef MY_NCURSES_H
#define MY_NCURSES_H

#include "lua.h"

int luaopen_myncurses(lua_State *L);
void l_ncurses_resize(lua_State *L);

#endif
