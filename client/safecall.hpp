#pragma once
/**
 * @file safecall.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Call Lua functions with backtrace reporting to stderr
 *
 */

struct lua_State;

/**
 * @brief Call a Lua function catching and reporting all errors
 *
 * @param L Lua interpreter handle
 * @param location Location to using in error reporting
 * @param args Number of function arguments on Lua stack
 * @return Result of lua_pcall
 */
int safecall(lua_State* L, char const* location, int args);

/**
 * @brief Find the main thread corresponding to an arbitrary thread.
 * 
 * This is used when registering callbacks so that the callbacks
 * are always run on the main thread. Continuation threads both need
 * to be resumed in a specific way and are also likely to be collected
 * before the callback completes.
 * 
 * @param L any thread 
 * @return main thread
 */
auto main_lua_state(lua_State* const L) -> lua_State*;
