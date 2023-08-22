#pragma once

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

class LuaRef
{
    lua_State *L;
    int ref;

public:
    LuaRef(lua_State *L, int const ref) : L{L}, ref{ref} {}
    ~LuaRef() { luaL_unref(L, LUA_REGISTRYINDEX, ref); }
    auto push() const -> void { lua_rawgeti(L, LUA_REGISTRYINDEX, ref); }
};