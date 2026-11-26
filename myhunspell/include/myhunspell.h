// Lua binding to libhunspell

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

// Pushes the myhunspell module table, whose only field is open(aff, dic),
// and registers the metatables of handles and suggestion lists.
int luaopen_myhunspell(struct lua_State* L);

#ifdef __cplusplus
}
#endif
