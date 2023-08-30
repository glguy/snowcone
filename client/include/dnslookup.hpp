/**
 * @file dnslookup.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Asyncronous dns lookup
 *
 */

#pragma once

struct lua_State;

/**
 * @brief Perform a dns lookup
 *
 * Takes a callback function that gets the list of results
 * or nil and an error message
 *
 * @param L Lua state
 * @return 0
 */
auto l_dnslookup(lua_State *L) -> int;
