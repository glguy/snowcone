// Lua binding to libidn's stringprep (RFC 3454), used to apply SASLprep
// and trace to SASL credentials.

#include "mystringprep.h"

#include <lauxlib.h>
#include <lua.h>

#include <stringprep.h>

#include <assert.h>
#include <stdlib.h>
#include <string.h>

// Lua: stringprep(str, profile) -> string
// Prepares str with the named libidn profile (e.g. 'SASLprep', 'trace')
// with no flags, so unassigned code points are allowed (query semantics).
// Raises an argument error if str contains a NUL byte, and raises
// "stringprep failed: <reason>" for any libidn failure, such as a
// prohibited character, a bidi violation, invalid UTF-8, or an unknown
// profile.
static int l_stringprep(lua_State* const L)
{
    size_t len;
    char const* const str = luaL_checklstring(L, 1, &len);
    char const* const profile = luaL_checkstring(L, 2);

    // libidn takes a C string, so an embedded NUL would truncate the input
    luaL_argcheck(L, strlen(str) == len, 1, "contains a NUL byte");

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
