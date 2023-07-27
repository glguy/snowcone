/**
 * @file applib.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Application Lua environment primitives and setup
 * 
 */

#pragma once

struct ircmsg;
struct configuration;

extern "C" {
#include "lua.h"
}

/// @brief Executes the Lua code found at the given filename
/// @param L Lua state
/// @param filename Filename of logic module
void load_logic(lua_State* L, char const* filename);

/// @brief Invoke the named application callback
/// The key is used to index the registered logic module.
/// All arguments on the current Lua stack are pass to the function.
/// @param L Lua state
/// @param key Name of callback
void lua_callback(lua_State* L, char const* key);

/// @brief Push an IRC message object onto the Lua stack
/// @param L Lua state
/// @param msg IRC message
void pushircmsg(lua_State* L, ircmsg const& msg);

/// @brief Install app functionality into global variables in the lua state
/// @param L Lua state
/// @param cfg Configuration object
void prepare_globals(lua_State* L, configuration const& cfg);
