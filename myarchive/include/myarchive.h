#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

int luaopen_myarchive(struct lua_State* const L);

#ifdef __cplusplus
}
#endif
