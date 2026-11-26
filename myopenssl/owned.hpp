#pragma once

// Lua-owned boxes for OpenSSL objects, so a Lua error can't leak them.
//
// The Lua library here is C, so a Lua error is a longjmp: it skips C++
// destructors and the frees on the path out. Anything OpenSSL allocates
// must therefore already be owned by Lua before the next call that can
// raise, which is nearly any Lua call that allocates. The pattern is to
// push an empty box first, then store the new object in it:
//
//     auto& ctx = Owned<EVP_PKEY_CTX, EVP_PKEY_CTX_free>::push(L);
//     ctx = EVP_PKEY_CTX_new(pkey, nullptr);
//
// If pushing the box raises, nothing exists yet to leak; once the object
// is stored, the box's __gc frees it whichever way the function ends.

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <openssl/crypto.h>

namespace myopenssl {

/// A box for a T* freed by Free, kept on the Lua stack while in use.
template <typename T, void (*Free)(T*)>
struct Owned
{
    /// Push an empty box and return a reference to its slot, which stays
    /// valid while the box is alive (Lua doesn't move userdata). The box's
    /// metatable is hidden from Lua code, which can't reach the object.
    static auto push(lua_State* const L) -> T*&
    {
        auto& slot = *static_cast<T**>(lua_newuserdatauv(L, sizeof(T*), 0));
        slot = nullptr;
        if (LUA_TNIL == lua_rawgetp(L, LUA_REGISTRYINDEX, &key))
        {
            lua_pop(L, 1);
            lua_createtable(L, 0, 3);
            lua_pushcfunction(L, gc);
            lua_setfield(L, -2, "__gc");
            lua_pushcfunction(L, gc);
            lua_setfield(L, -2, "__close");
            lua_pushboolean(L, false);
            lua_setfield(L, -2, "__metatable");
            lua_pushvalue(L, -1);
            lua_rawsetp(L, LUA_REGISTRYINDEX, &key);
        }
        lua_setmetatable(L, -2);
        return slot;
    }

    /// Free the object now, rather than at collection, and empty the slot
    static auto reset(T*& slot) -> void
    {
        if (nullptr != slot)
        {
            Free(slot);
            slot = nullptr;
        }
    }

private:
    /// Registry key of this box type's metatable
    static inline char key;

    /// __gc and __close: free the object, if any. Registered without the
    /// dispatch boundary, so it leaves the OpenSSL error queue alone when a
    /// collection runs while an error is being reported.
    static auto gc(lua_State* const L) -> int
    {
        reset(*static_cast<T**>(lua_touserdata(L, 1)));
        return 0;
    }
};

/// OPENSSL_free is a macro; this is a function Owned can take
template <typename T>
auto openssl_free(T* const p) -> void
{
    OPENSSL_free(p);
}

} // namespace myopenssl
