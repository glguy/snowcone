#pragma once
/**
 * @file irc.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief IRC connection logic
 *
 */

#include <vector>

struct lua_State;
struct irctag;
struct ircmsg;

/**
 * @brief Starts the connection for the app
 */
auto l_start_irc(lua_State* L) -> int;

auto pushtags(lua_State* L, std::vector<irctag> const& tags) -> void;
auto pushircmsg(lua_State* const L, ircmsg const& msg) -> void;
