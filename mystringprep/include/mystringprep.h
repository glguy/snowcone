// Lua binding to libidn's stringprep

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

// Pushes the mystringprep module table, whose only field is stringprep.
int luaopen_mystringprep(struct lua_State* L);

#ifdef __cplusplus
}
#endif
