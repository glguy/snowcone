#pragma once
/**
 * @file userdata.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Helpers for using Lua userdata
 *
 */

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <concepts>

template<typename T> char const* udata_name;

/**
 * @brief Push a new userdata onto the stack
 *
 * The metatable is only created the first time and is cached afterward
 *
 * @tparam T Allocate enough space to point to this type
 * @param L Lua State
 * @param nuvalue Number of uservalues
 * @param push_metatable Metatable initialization callback
 * @return T* Pointer to allocated space
 */
template <typename T>
T * new_udata(lua_State * const L, int const nuvalue, std::invocable auto push_metatable) {

    auto const ptr = static_cast<T*>(lua_newuserdatauv(L, sizeof (T), nuvalue));

    if (luaL_newmetatable(L, udata_name<T>)) {
        push_metatable();
    }
    lua_setmetatable(L, -2);

    return ptr;
}

/**
 * @brief Retrieve pointer to allocation from a userdata
 *
 * This function raises a Lua error on failure
 *
 * @tparam T Type of allocation
 * @param L Lua State
 * @param ud Index of argument
 * @return T* Pointer to allocation
 */
template <typename T>
T* check_udata(lua_State *L, int ud) {
    return static_cast<T*>(luaL_checkudata(L, ud, udata_name<T>));
}

// Simple allocator for non-user-facing objects
template <typename T, typename... Args>
auto new_object(lua_State* const L, Args&&... args) -> T&
{
    static luaL_Reg const MT[] = {
        {"__gc", [](auto const L){
            auto const ptr = reinterpret_cast<T*>(lua_touserdata(L, 1));
            ptr->~T();
            return 0;
        }},
        {}
    };

    auto const ptr = reinterpret_cast<T*>(lua_newuserdatauv(L, sizeof (T), 0));

    luaL_newlibtable(L, MT);
    luaL_setfuncs(L, MT, 0);
    lua_setmetatable(L, -2);

    std::construct_at<T>(ptr, std::forward<Args>(args)...);
    return *ptr;
}
