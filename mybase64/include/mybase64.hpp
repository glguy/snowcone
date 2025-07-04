/**
 * @file mybase64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding for Lua
 *
 */
#pragma once

struct lua_State;

extern "C" auto luaopen_mybase64(lua_State* const L) -> int;
