#include "strings.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstring>

auto push_string(lua_State *const L, std::string_view const str) -> char const *
{
    return lua_pushlstring(L, std::data(str), std::size(str));
}

auto mutable_string_arg(lua_State * const L, int const i) -> char*
{
    std::size_t len;
    auto const str = luaL_checklstring(L, 1, &len);
    auto const buffer = static_cast<char*>(lua_newuserdatauv(L, len + 1, 0));
    std::strcpy(buffer, str);
    return buffer;
}
