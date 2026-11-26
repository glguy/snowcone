/**
 * @file mybase64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding for Lua
 *
 */
#pragma once

struct lua_State;

/**
 * @brief Lua module entry point, registered as "mybase64" by the client.
 *
 * Pushes a module table with from_base64 and to_base64.
 *
 * @param L Lua state
 * @return int 1
 */
extern "C" auto luaopen_mybase64(lua_State* const L) -> int;
