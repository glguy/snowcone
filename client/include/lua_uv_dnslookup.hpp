/**
 * @file lua_uv_dnslookup.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief DNS lookups in Lua using libuv
 *
 */

#pragma once

struct lua_State;

/**
 * @brief Lua function from hostname to addresses.
 *
 * Lua arguments:
 * * hostname as string
 * * callback as below
 *
 * Callback arguments:
 * * Success: array of textual addresses
 * * Failure: nil, Returns nil and error message on failure.
 *
 * @param L Lua state
 * @return int 0
 */
int l_dnslookup(lua_State* L);
