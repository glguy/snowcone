#pragma once
/**
 * @file applib.hpp
 * @brief Application Lua environment primitives and setup
 * @author Eric Mertens (emertens@gmail.com)
 */

struct lua_State;

/// @brief Invoke the named application callback
/// Calls the module registered by snowcone.setmodule as module(key, ...),
/// with the args values on top of the stack, through safecall. The args
/// values are popped whether or not a module is registered.
/// @param L Lua state
/// @param key Name of callback
/// @param args Number of callback arguments
/// @return true if the call succeeded; false if it raised an error or no
/// module is registered
auto lua_callback(lua_State* L, char const* key, int args) -> bool;

/// @brief Install app functionality into global variables in the lua state
/// Opens the standard and bundled libraries, defines the `snowcone` table
/// and replaces `print`.
/// @param L Lua state
/// @param argc Number of script arguments
/// @param argv Script arguments, exposed to Lua as `arg`: argv[1] (the
/// program) at index 0, the executable at -1, and its arguments from 1
auto prepare_globals(lua_State* L, int argc, char const* const* argv) -> void;
