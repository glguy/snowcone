/**
 * @file lua_uv_timer.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua binding to libuv timers
 * 
 */

#pragma once

extern "C" {
#include "lua.h"
}

#include <uv.h>

/**
 * @brief Construct a new libuv timer
 * 
 * Pushes new object onto Lua stack
 * 
 * Lua object methods:
 * * start
 * * stop
 * * close
 * 
 * @param L Lua state 
 * @param loop Current libuv loop
 */
void push_new_uv_timer(lua_State *L, uv_loop_t *);
