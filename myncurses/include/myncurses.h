#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include "lua.h"

int luaopen_myncurses(lua_State *L);
void l_ncurses_resize(lua_State *L);


#ifdef __cplusplus
}
#endif
