#pragma once
/**
 * @file boundary.hpp
 * @brief Keep C++ exceptions from crossing into Lua.
 *
 * Lua is built as C, so a C++ exception that unwinds through Lua's frames
 * leaves the lua_State corrupted. Every lua_CFunction registered from C++
 * code that might throw is registered as boundary<F> instead of F.
 *
 * Inside F, prefer to work in three phases:
 * 1. Validate arguments with luaL_check* and raw table access while only
 *    trivially destructible locals are live (a Lua error longjmps past
 *    destructors).
 * 2. Do the C++ work without making Lua calls that can raise.
 * 3. Push results, using luaL_checkstack before a data-dependent number of
 *    pushes.
 */

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <cstdio>
#include <exception>

/**
 * @brief Call F, converting any escaping C++ exception into a Lua error.
 *
 * The error is raised only after the catch block has finished, so no C++
 * object is live when luaL_error longjmps.
 *
 * @tparam F Function to protect
 * @param L Lua state
 * @return Results of F
 */
template <lua_CFunction F>
auto boundary(lua_State* const L) -> int
{
    char message[256];
    try
    {
        return F(L);
    }
    catch (std::exception const& e)
    {
        std::snprintf(message, sizeof message, "%s", e.what());
    }
    catch (...)
    {
        std::snprintf(message, sizeof message, "unknown C++ exception");
    }
    return luaL_error(L, "%s", message);
}
