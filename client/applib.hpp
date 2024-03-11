#pragma once
/**
 * @file applib.hpp
 * @brief Application Lua environment primitives and setup
 * @author Eric Mertens (emertens@gmail.com)
 */

struct lua_State;

/// @brief Executes the Lua code found at the given filename
/// @param L Lua state
/// @param filename Filename of logic module
auto load_logic(lua_State* L, char const* filename) -> bool;

/// @brief Invoke the named application callback
/// The key is used to index the registered logic module.
/// @param L Lua state
/// @param key Name of callback
/// @param args Number of callback arguments
/// @return true on success and false on failure
auto lua_callback(lua_State* L, char const* key, int args) -> bool;

/// @brief Install app functionality into global variables in the lua state
/// @param L Lua state
/// @param cfg Configuration object
auto prepare_globals(lua_State* L, int argc, char const* const* argv) -> void;
