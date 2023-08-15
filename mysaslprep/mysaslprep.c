#include "mysaslprep.h"

#include <lua.h>
#include <lauxlib.h>

#include <stringprep.h>

#include <stdlib.h>
#include <string.h>
#include <assert.h>

static int l_saslprep(lua_State *const L)
{
    size_t len;
    char const *str = luaL_checklstring(L, 1, &len);

    luaL_Buffer B;
    size_t buflen = len + 1;
    char *buffer = luaL_buffinitsize(L, &B, buflen);
    strcpy(buffer, str);

    for (;;)
    {
        int const result = stringprep(buffer, buflen, (Stringprep_profile_flags)0, stringprep_saslprep);
        switch (result)
        {
        case STRINGPREP_OK:
            luaL_pushresultsize(&B, strlen(buffer));
            return 1;
        case STRINGPREP_TOO_SMALL_BUFFER:
            buflen *= 2;
            luaL_prepbuffsize(&B, buflen);
            strcpy(buffer, str);
            break;
        default:
        { // fatal error code
            char const *const err = stringprep_strerror((Stringprep_rc)result);
            luaL_error(L, "stringprep failed: %s", err);
            return 0;
        }
        }
    }
}

static luaL_Reg M[] = {
    {"saslprep", l_saslprep},
    {}};

int luaopen_mysaslprep(lua_State *L)
{
    luaL_newlib(L, M);
    return 1;
}
