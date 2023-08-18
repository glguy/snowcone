/**
 * @file userdata.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Helpers for using Lua userdata
 *
 */

#pragma once

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <concepts>

template<typename T> char const* udata_name;

template <typename T>
T * new_udata(lua_State *L, int nuvalue, std::invocable auto k) {

    auto ptr = static_cast<T*>(lua_newuserdatauv(L, sizeof (T), nuvalue));

    if (luaL_newmetatable(L, udata_name<T>)) {
        k();
    }
    lua_setmetatable(L, -2);

    return ptr;
}

template <typename T>
T* check_udata(lua_State *L, int ud) {
    return static_cast<T*>(luaL_checkudata(L, ud, udata_name<T>));
}
