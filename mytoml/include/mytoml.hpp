/**
 * @file mytoml.hpp
 * @brief TOML parsing for Lua
 *
 */
#pragma once

struct lua_State;

/// Open the mytoml library: push a new table holding parse_toml, and
/// return 1. Suitable for luaL_requiref.
extern "C" auto luaopen_mytoml(lua_State*) -> int;
