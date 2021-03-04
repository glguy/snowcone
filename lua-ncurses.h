
#ifndef LUA_NCURSES_H
#define LUA_NCURSES_H

#include "lua5.3/lua.h"

int luaopen_ncurses(lua_State *L);
void l_ncurses_resize(lua_State *L);

#endif