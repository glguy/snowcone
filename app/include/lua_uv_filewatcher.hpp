/**
 * @file lua_uv_filewatcher.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua binding to libuv file watcher
 * 
 */

#pragma once

extern "C" {
#include "lua.h"
}

#include <uv.h>

/**
 * @brief Construct a new libuv file watcher
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
void push_new_fs_event(lua_State *L, uv_loop_t *loop);
