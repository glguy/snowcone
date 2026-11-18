#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

int luaopen_myhunspell(struct lua_State* L);

#ifdef __cplusplus
}
#endif
