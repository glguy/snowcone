#pragma once
/**
 * @file safecall.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Call Lua functions with backtrace reporting to stderr
 *
 */

#include <string_view>

struct lua_State;

/**
 * @brief Call a Lua function catching and reporting all errors
 *
 * Stack: expects the function and then its args arguments on top of the
 * stack. They are all consumed and any results are discarded, so the stack
 * drops by args + 1 whether or not the call succeeds.
 *
 * On error, the message and a traceback are written to stderr after
 * endwin(), and safecall_failures() counts it.
 *
 * @param L Lua interpreter handle
 * @param location Description of the call site, used in error reports
 * @param args Number of function arguments on Lua stack
 * @return Result of lua_pcall
 */
int safecall(lua_State* L, std::string_view location, int args);

/// @brief Number of safecall invocations that ended in a Lua error
auto safecall_failures() -> int;
