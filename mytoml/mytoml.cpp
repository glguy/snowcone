#include "mytoml.hpp"
#include "parse_toml.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

static const luaL_Reg M[] {
    {"parse_toml", mytoml::l_parse_toml},
    {}
};

extern "C" auto luaopen_mytoml(lua_State* const L) -> int
{
    luaL_newlib(L, M);
    return 1;
}
