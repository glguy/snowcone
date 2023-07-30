/**
 * @file irc.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief IRC connection logic
 *
 */

#pragma once

struct lua_State;

/**
 * @brief Starts the connection for the app
 */
auto start_irc(lua_State* L) -> int;
