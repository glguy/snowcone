/**
 * @file applib.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Application Lua environment primitives and setup
 *
 */

#pragma once

struct ircmsg;
struct configuration;

struct lua_State;

/// @brief Executes the Lua code found at the given filename
/// @param L Lua state
/// @param filename Filename of logic module
auto load_logic(lua_State* L, char const* filename) -> bool;

/// @brief Invoke the named application callback
/// The key is used to index the registered logic module.
/// All arguments on the current Lua stack are pass to the function.
/// @param L Lua state
/// @param key Name of callback
/// @return true on success and false on failure
auto lua_callback(lua_State* L, char const* key) -> bool;

/// @brief Install app functionality into global variables in the lua state
/// @param L Lua state
/// @param cfg Configuration object
auto prepare_globals(lua_State* L, int argc, char ** argv) -> void;
