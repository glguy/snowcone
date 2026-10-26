#pragma once
/**
 * @file dnslookup.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Asynchronous dns lookup
 *
 */

struct lua_State;

/**
 * @brief Perform a dns lookup
 *
 * Lua: dnslookup(hostname, callback) -> handle
 *
 * The callback runs once, as callback(nil, address...) on success or
 * callback(message) on failure. handle:cancel() drops the callback so it
 * never runs. Collecting the handle doesn't cancel the lookup.
 *
 * @param L Lua state
 * @return 1
 */
auto l_dnslookup(lua_State* L) -> int;
