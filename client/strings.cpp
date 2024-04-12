#include "strings.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstring>

auto mutable_string_arg(lua_State * const L, int const i) -> char*
{
    std::size_t len;
    auto const str = check_string_view(L, 1);
    auto const buffer = static_cast<char*>(lua_newuserdatauv(L, str.size() + 1, 0));
    std::strcpy(buffer, str.data());
    return buffer;
}

auto check_string_view(lua_State * L, int arg) -> std::string_view
{
    std::size_t len;
    auto const str = luaL_checklstring(L, arg, &len);
    return {str, len};
}
