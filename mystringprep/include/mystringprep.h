#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

int luaopen_mystringprep(struct lua_State *L);

#ifdef __cplusplus
}
#endif
