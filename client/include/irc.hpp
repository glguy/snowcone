/**
 * @file irc.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief IRC connection logic
 *
 */

#pragma once

struct lua_State;
struct irctag;

#include <vector>

/**
 * @brief Starts the connection for the app
 */
auto start_irc(lua_State* L) -> int;

auto pushtags(lua_State* L, std::vector<irctag> const& tags) -> void;
