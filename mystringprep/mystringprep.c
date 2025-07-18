#include "mystringprep.h"

#include <lauxlib.h>
#include <lua.h>

#include <stringprep.h>

#include <assert.h>
#include <stdlib.h>
#include <string.h>

static int l_stringprep(lua_State* const L)
{
    char const* const str = luaL_checkstring(L, 1);
    char const* const profile = luaL_checkstring(L, 2);

    char* output;

    int const result = stringprep_profile(str, &output, profile, (Stringprep_profile_flags)0);
    switch (result)
    {
    case STRINGPREP_OK:
        lua_pushstring(L, output);
        free(output);
        return 1;
    default: { // fatal error code
        char const* const err = stringprep_strerror((Stringprep_rc)result);
        return luaL_error(L, "stringprep failed: %s", err);
    }
    }
}

static const luaL_Reg M[] = {
    {"stringprep", l_stringprep},
    {0}
};

int luaopen_mystringprep(lua_State* L)
{
    luaL_newlib(L, M);
    return 1;
}
