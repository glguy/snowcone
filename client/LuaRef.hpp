#pragma once

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

class LuaRef
{
    lua_State* L_;
    int ref_;

public:
    LuaRef() noexcept
        : L_{nullptr}
        , ref_{LUA_NOREF}
    {
    }

    LuaRef(lua_State* const L, int const cb) noexcept
        : L_{L}
        , ref_{cb}
    {
    }

    explicit LuaRef(LuaRef const& value)
        : L_{value.L_}
        , ref_{LUA_NOREF}
    {
        if (value)
        {
            value.push();
            ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);
        }
    }

    LuaRef(LuaRef&& value) noexcept
        : LuaRef{}
    {
        swap(value);
    }

    auto operator=(LuaRef&& value) noexcept -> LuaRef&
    {
        swap(value);
        return *this;
    }

    auto operator=(LuaRef const& value) -> LuaRef&
    {
        if (&value != this)
        {
            *this = LuaRef{value};
        }
        return *this;
    }

    ~LuaRef()
    {
        clear();
    }

    explicit operator bool() const noexcept
    {
        return ref_ != LUA_NOREF;
    }

    static auto create(lua_State* const L) -> LuaRef
    {
        return {L, luaL_ref(L, LUA_REGISTRYINDEX)};
    }

    auto clear() -> void
    {
        if (*this)
        {
            luaL_unref(L_, LUA_REGISTRYINDEX, ref_);
            L_ = nullptr;
            ref_ = LUA_NOREF;
        }
    }

    auto push() const noexcept -> void
    {
        lua_rawgeti(L_, LUA_REGISTRYINDEX, ref_);
    }

    auto get_lua() const noexcept -> lua_State*
    {
        return L_;
    }

    auto swap(LuaRef& v) noexcept -> void
    {
        std::swap(L_, v.L_);
        std::swap(ref_, v.ref_);
    }
};
