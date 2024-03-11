#pragma once

#include <string_view>

struct lua_State;

/**
 * @brief Push string_view value onto Lua stack
 *
 * @param L Lua
 * @param str string
 * @return char const* string in Lua memory
 */
auto push_string(lua_State * L, std::string_view str) -> char const *;

/**
 * @brief Check argument as a mutable string and pushes buffer onto Lua stack
 * 
 * @param L Lua
 * @param i Argument index
 * @return Pointer to mutable copy of string
 * @throw Raise Lua error for bad argument
 */
auto mutable_string_arg(lua_State* L, int i) -> char*;
