#pragma once

#include <string_view>

extern "C" {
#include <lua.h>
}

/**
 * @brief Push string_view value onto Lua stack
 *
 * @param L Lua
 * @param str string
 * @return char const* string in Lua memory
 */
inline auto push_string(lua_State * const L, std::string_view const str) -> char const *
{
    return lua_pushlstring(L, std::data(str), std::size(str));
}

/**
 * @brief Check argument as a mutable string and pushes buffer onto Lua stack
 *
 * @param L Lua
 * @param i Argument index
 * @return Pointer to mutable copy of string
 * @throw Raise Lua error for bad argument
 */
auto mutable_string_arg(lua_State* L, int i) -> char*;

auto check_string_view(lua_State * L, int arg) -> std::string_view;
