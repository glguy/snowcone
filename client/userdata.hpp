#pragma once
/**
 * @file userdata.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Helpers for using Lua userdata
 *
 */

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <concepts>
#include <memory>

/// The metatable name for userdata holding a T. Each type specializes it
/// before its first use; there is no default, so a type without one fails
/// to link instead of using a null name.
template <typename T>
extern char const* const udata_name;

/**
 * @brief Push a new userdata onto the stack
 *
 * The metatable is created the first time and cached in the registry under
 * udata_name<T> afterward. The userdata is left on top of the stack. Raises
 * a Lua error if allocation fails.
 *
 * @tparam T Allocate space for one T; it is not constructed, so the caller
 * constructs it (std::construct_at) before anything can finalize it
 * @param L Lua State
 * @param nuvalue Number of uservalues
 * @param push_metatable Called only when the metatable is new, with it on
 * top of the stack, to fill it in
 * @return T* Pointer to allocated space
 */
template <typename T>
T* new_udata(lua_State* const L, int const nuvalue, std::invocable auto push_metatable)
{

    auto const ptr = static_cast<T*>(lua_newuserdatauv(L, sizeof(T), nuvalue));

    if (luaL_newmetatable(L, udata_name<T>))
    {
        push_metatable();
    }
    lua_setmetatable(L, -2);

    return ptr;
}

/**
 * @brief Retrieve pointer to allocation from a userdata
 *
 * This function raises a Lua error unless the value at ud is a userdata
 * with udata_name<T>'s metatable
 *
 * @tparam T Type of allocation
 * @param L Lua State
 * @param ud Index of argument
 * @return T* Pointer to allocation
 */
template <typename T>
T* check_udata(lua_State* L, int ud)
{
    return static_cast<T*>(luaL_checkudata(L, ud, udata_name<T>));
}
