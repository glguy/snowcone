#pragma once
/**
 * @file lua.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Lua bindings for IRC connections and parsed IRC messages
 *
 */

#include <vector>

struct lua_State;
struct irctag;
struct ircmsg;

/**
 * @brief Lua binding snowcone.connect(host, port, layers, callback) --> handle
 *
 * Validates its arguments (raising a Lua error for a bad one) and starts an
 * IRC connection whose events are delivered to callback. See the definition
 * for the layers, events and handle methods.
 */
auto l_start_irc(lua_State* L) -> int;

/// Push a table mapping each tag key to its value; a repeated key keeps its
/// last value
auto pushtags(lua_State* L, std::vector<irctag> const& tags) -> void;

/// Push a message table: `tags` (always present), `source` (only when
/// non-empty), `command` (an integer when the whole command parses as a
/// decimal integer, as numerics do, else the string) and the arguments at 1..n
auto pushircmsg(lua_State* const L, ircmsg const& msg) -> void;
