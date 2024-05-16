#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

int luaopen_myncurses(struct lua_State* L);
void l_ncurses_resize(struct lua_State* L);

#ifdef __cplusplus
}
#endif
