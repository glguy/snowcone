#include "lua_uv_dnslookup.hpp"

#include "app.hpp"
#include "safecall.hpp"
#include "uv.hpp"
#include "uvaddrinfo.hpp"

extern "C" {
#include "lauxlib.h"
}
#include <uv.h>

#include <iterator>
#include <memory>
namespace {

void push_addrinfos(lua_State* L, uv_loop_t* loop, addrinfo* ai)
{
    AddrInfo const addrinfos {ai};

    auto n = std::distance(addrinfos.begin(), addrinfos.end());
    lua_Integer i = 1;
    lua_createtable(L, n, 0); // printable addresses

    for (auto&& a : addrinfos) {
        uv_getnameinfo_t req;
        uvok(uv_getnameinfo(loop, &req, nullptr, a.ai_addr, NI_NUMERICHOST));
        lua_pushstring(L, req.host);
        lua_rawseti(L, -2, i++);
    }
}

void on_dnslookup(uv_getaddrinfo_t* req, int status, addrinfo* res)
{
    auto const a = static_cast<app*>(req->loop->data);
    auto const L = a->L;

    // recover the callback function from the registry
    lua_rawgetp(L, LUA_REGISTRYINDEX, req);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, req);

    delete req;

    if (0 == status) {
        push_addrinfos(L, &a->loop, res);
        lua_pushnil(L);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(status));
    }

    safecall(L, "dnslookup callback", 2);
}

} // namespace

int l_dnslookup(lua_State* L)
{
    auto const a = app::from_lua(L);
    char const* hostname = luaL_checkstring(L, 1);
    luaL_checkany(L, 2);
    lua_settop(L, 2);

    addrinfo hints {};
    hints.ai_socktype = SOCK_STREAM;

    auto req = std::make_unique<uv_getaddrinfo_t>();
    uvok(uv_getaddrinfo(&a->loop, req.get(), on_dnslookup, hostname, nullptr, &hints));

    // save callback function into the registry
    lua_rawsetp(L, LUA_REGISTRYINDEX, req.release());

    return 0;
}
