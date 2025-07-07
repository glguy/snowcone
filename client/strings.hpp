#pragma once

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstddef>
#include <string_view>

/**
 * @brief Push string_view value onto Lua stack
 *
 * @param L Lua
 * @param str string
 * @return char const* string in Lua memory
 */
inline auto push_string(lua_State* const L, std::string_view const str) -> char const*
{
    return lua_pushlstring(L, std::data(str), std::size(str));
}

inline auto check_string_view(lua_State* L, int const arg) -> std::string_view
{
    std::size_t len;
    auto const str = luaL_checklstring(L, arg, &len);
    return {str, len};
}
