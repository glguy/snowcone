#pragma once

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

class LuaRef final
{
    lua_State *L_;
    int ref_;

public:
    LuaRef(lua_State *L, int const ref) : L_{L}, ref_{ref} {}

    ~LuaRef() { release(); }

    LuaRef(LuaRef && other) : L_{other.L_}, ref_{other.ref_} {
        other.L_ = nullptr;
        other.ref_ = 0;
    }

    auto get_lua() const -> lua_State *
    {
        return L_;
    }

    auto get_ref() const -> int
    {
        return ref_;
    }

    auto operator=(LuaRef && other) -> LuaRef& {
        reset();
        L_ = other.L_;
        ref_ = other.release();
        return *this;
    }

    auto push() const -> void {
        if (L_) {
            lua_rawgeti(L_, LUA_REGISTRYINDEX, ref_);
        } else {
            lua_pushnil(L_);
        }
    }

    /**
     * @brief Unreferences the referenced object
     */
    auto reset() -> void {
        if (L_) {
            luaL_unref(L_, LUA_REGISTRYINDEX, ref_);
            release();
        }
    }

    auto release() -> int {
        auto const r = ref_;
        L_ = nullptr;
        ref_ = 0;
        return r;
    }
};
