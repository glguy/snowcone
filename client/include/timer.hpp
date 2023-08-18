/**
 * @file lua_uv_timer.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua binding to libuv timers
 *
 */

#pragma once

struct lua_State;

/**
 * @brief Construct a new libuv timer
 *
 * Pushes new object onto Lua stack and return 1
 *
 * Lua object methods:
 * * start
 * * stop
 * * close
 *
 * @param L Lua state
 * @param loop Current libuv loop
 */
auto push_new_timer(lua_State *L) -> int;
