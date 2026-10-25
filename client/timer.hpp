#pragma once
/**
 * @file timer.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Asyncronous timer objects
 *
 */

struct lua_State;

/**
 * @brief Construct a new timer
 *
 * Lua object methods:
 * * start(milliseconds, callback): replaces any wait in progress; the
 *   callback runs at most once, with no arguments
 * * cancel(): after it returns, no callback from an earlier start() runs
 *
 * A collected timer's callback never runs. After finalization (a timer
 * reached through a weak table or resurrection) cancel() does nothing and
 * start() raises an error.
 *
 * @param L Lua state
 * @return 1
 */
auto l_new_timer(lua_State* L) -> int;
