#include "strings.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <cstring>

auto check_string_view(lua_State* const L, int const arg) -> std::string_view
{
    std::size_t len;
    auto const str = luaL_checklstring(L, arg, &len);
    return {str, len};
}
