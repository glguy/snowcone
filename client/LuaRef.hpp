#pragma once

/**
 * @file LuaRef.hpp
 * @brief Defines the LuaRef class for managing references to Lua objects in the registry.
 */

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <utility>

/**
 * @class LuaRef
 * @brief Manages a reference to a Lua object stored in the Lua registry.
 *
 * This class encapsulates a reference to a Lua object, ensuring proper
 * reference counting and cleanup. It supports move and copy semantics.
 */
class LuaRef
{
    lua_State* L_; ///< Pointer to the associated Lua state.
    int ref_;      ///< Registry reference to the Lua object.

    /**
     * @brief Constructs a LuaRef from a Lua state and a registry reference.
     * @param L Pointer to the Lua state.
     * @param cb Registry reference to the Lua object.
     */
    LuaRef(lua_State* const L, int const cb) noexcept
        : L_{L}
        , ref_{cb}
    {
    }

public:
    /**
     * @brief Copy constructor. Creates a new reference to the same Lua object.
     * @param value The LuaRef to copy.
     */
    explicit LuaRef(LuaRef const& value)
        : L_{value.L_}
        , ref_{LUA_NOREF}
    {
        if (value.ref_ != LUA_NOREF)
        {
            value.push();
            ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);
        }
    }

    /**
     * @brief Move constructor.
     * @param value The LuaRef to move from.
     */
    LuaRef(LuaRef&& value) noexcept
        : L_{}
        , ref_{LUA_NOREF}
    {
        swap(*this, value);
    }

    /**
     * @brief Move assignment operator.
     * @param value The LuaRef to move from.
     * @return Reference to this object.
     */
    auto operator=(LuaRef&& value) noexcept -> LuaRef&
    {
        swap(*this, value);
        return *this;
    }

    /**
     * @brief Copy assignment operator.
     * @param value The LuaRef to copy from.
     * @return Reference to this object.
     */
    auto operator=(LuaRef const& value) -> LuaRef&
    {
        if (&value != this)
        {
            *this = LuaRef{value};
        }
        return *this;
    }

    /**
     * @brief Destructor. Releases the Lua registry reference if valid.
     */
    ~LuaRef()
    {
        if (ref_ != LUA_NOREF)
        {
            luaL_unref(L_, LUA_REGISTRYINDEX, ref_);
        }  
    }

    /**
     * @brief Creates a LuaRef from the value on top of the Lua stack.
     * 
     * The top value of the stack is consumed by this operation.
     * 
     * @param L Pointer to the Lua state.
     * @return A new LuaRef referencing the value.
     */
    static auto create(lua_State* const L) -> LuaRef
    {
        return LuaRef{L, luaL_ref(L, LUA_REGISTRYINDEX)};
    }

    /**
     * @brief Pushes the referenced Lua object onto the Lua stack.
     */
    auto push() const noexcept -> void
    {
        lua_rawgeti(L_, LUA_REGISTRYINDEX, ref_);
    }

    /**
     * @brief Returns the associated Lua state.
     * @return Pointer to the Lua state.
     */
    auto get_lua() const noexcept -> lua_State*
    {
        return L_;
    }

    /**
     * @brief Swaps two LuaRef objects.
     * @param first First LuaRef.
     * @param second Second LuaRef.
     */
    friend auto swap(LuaRef& first, LuaRef& second) noexcept -> void
    {
        using std::swap;
        swap(first.L_, second.L_);
        swap(first.ref_, second.ref_);
    }
};
