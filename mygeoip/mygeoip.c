// Lua binding for libGeoIP name lookups; see mygeoip.h for the Lua API
#include "mygeoip.h"

#include <GeoIP.h>

#include <lauxlib.h>
#include <lua.h>

#include <stdlib.h>

/// Registry name of the metatable for database userdata (a GeoIP* box)
static char const* db_type_name = "GeoIP*";

/// The open database in argument 1; raises an argument error when it isn't
/// a database or has been closed.
static GeoIP* check_db(lua_State* L)
{
    GeoIP** geoip = luaL_checkudata(L, 1, db_type_name);
    luaL_argcheck(L, *geoip != NULL, 1, "database is closed");
    return *geoip;
}

/// The editions libGeoIP 1.6.12 looks up names in, by IPv4 address
/// (_get_name_gl) and by IPv6 address (_get_name_v6_gl). For any other, it
/// prints "Invalid database type" to stdout, over the screen, so the
/// methods check first.
static int const v4_name_editions[] = {
    GEOIP_ORG_EDITION, GEOIP_ISP_EDITION, GEOIP_DOMAIN_EDITION,
    GEOIP_ASNUM_EDITION, GEOIP_ACCURACYRADIUS_EDITION,
    GEOIP_NETSPEED_EDITION_REV1, GEOIP_USERTYPE_EDITION,
    GEOIP_REGISTRAR_EDITION, GEOIP_LOCATIONA_EDITION, GEOIP_CITYCONF_EDITION,
    GEOIP_COUNTRYCONF_EDITION, GEOIP_REGIONCONF_EDITION,
    GEOIP_POSTALCONF_EDITION,
};
static int const v6_name_editions[] = {
    GEOIP_ORG_EDITION_V6, GEOIP_ISP_EDITION_V6, GEOIP_DOMAIN_EDITION_V6,
    GEOIP_ASNUM_EDITION_V6, GEOIP_ACCURACYRADIUS_EDITION_V6,
    GEOIP_NETSPEED_EDITION_REV1_V6, GEOIP_USERTYPE_EDITION_V6,
    GEOIP_REGISTRAR_EDITION_V6, GEOIP_LOCATIONA_EDITION_V6,
};

/// The open database in argument 1, if its edition is one of the n in
/// editions; raises "<method>: wrong database edition" otherwise.
static GeoIP* check_db_edition(lua_State* L, char const* method, int const* editions, size_t n)
{
    GeoIP* geoip = check_db(L);
    int const edition = GeoIP_database_edition(geoip);
    for (size_t i = 0; i < n; i++)
    {
        if (editions[i] == edition)
        {
            return geoip;
        }
    }
    luaL_error(L, "%s: wrong database edition", method);
    return NULL;
}

/// __gc and __close: frees the database of any edition and nulls the
/// pointer, so a repeated call is a no-op.
static int close_db(lua_State* L)
{
    GeoIP** geoip = luaL_checkudata(L, 1, db_type_name);
    if (*geoip != NULL)
    {
        GeoIP_delete(*geoip);
        *geoip = NULL;
    }
    return 0;
}

/// open_db(edition) --> db: opens the default database file for that
/// edition; raises an argument error for an edition that isn't one of the
/// module's constants, and "Failed to open" when the file is missing or
/// unreadable.
static int open_db(lua_State* L)
{
    lua_Integer type = luaL_checkinteger(L, 1);
    luaL_argcheck(L, GEOIP_COUNTRY_EDITION <= type && type < NUM_DB_TYPES, 1, "unknown edition");

    // The box comes first: if allocating it raises, no database is open yet
    GeoIP** ptr = lua_newuserdatauv(L, sizeof *ptr, 0);
    *ptr = NULL;
    luaL_setmetatable(L, db_type_name);

    *ptr = GeoIP_open_type((int)type, GEOIP_SILENCE);
    if (NULL == *ptr)
        return luaL_error(L, "Failed to open");
    return 1;
}

/// db:get_name_by_addr(addr) --> string|nil: name for a dotted IPv4
/// address; nil when there is no entry. An unparsable address looks up
/// 0.0.0.0. Raises on a closed db, or one whose edition has no IPv4 names.
static int get_name_by_addr(lua_State* L)
{
    GeoIP* geoip = check_db_edition(L, "get_name_by_addr", v4_name_editions,
                                    sizeof v4_name_editions / sizeof *v4_name_editions);
    char const* addr = luaL_checkstring(L, 2);
    GeoIPLookup gl = {0};
    char* org = GeoIP_name_by_addr_gl(geoip, addr, &gl);
    lua_pushstring(L, org);
    free(org);
    return 1;
}

/// db:get_name_by_addr_v6(addr) --> string|nil: name for an IPv6 address;
/// nil when there is no entry. Raises on a closed db, or one whose edition
/// has no IPv6 names.
static int get_name_by_addr_v6(lua_State* L)
{
    GeoIP* geoip = check_db_edition(L, "get_name_by_addr_v6", v6_name_editions,
                                    sizeof v6_name_editions / sizeof *v6_name_editions);
    char const* addr = luaL_checkstring(L, 2);
    GeoIPLookup gl = {0};
    char* org = GeoIP_name_by_addr_v6_gl(geoip, addr, &gl);
    lua_pushstring(L, org);
    free(org);
    return 1;
}

/// Module functions
static luaL_Reg M[] = {
    {"open_db", open_db},
    {0},
};

/// Database methods, installed as the metatable's __index
static luaL_Reg DbM[] = {
    {"get_name_by_addr", get_name_by_addr},
    {"get_name_by_addr_v6", get_name_by_addr_v6},
    {0},
};

/// EDITION(x) sets field "x" of the table on top of the stack to the value
/// of the constant x; the name is stringized unexpanded.
#define EDITION_STR(_s) #_s
#define EDITION(x)         \
    lua_pushinteger(L, x); \
    lua_setfield(L, -2, EDITION_STR(x));

int luaopen_mygeoip(lua_State* L)
{
    if (luaL_newmetatable(L, db_type_name))
    {
        lua_pushcfunction(L, close_db);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, close_db);
        lua_setfield(L, -2, "__close");

        luaL_newlib(L, DbM);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    luaL_newlib(L, M);

    EDITION(GEOIP_COUNTRY_EDITION)
    EDITION(GEOIP_REGION_EDITION_REV0)
    EDITION(GEOIP_CITY_EDITION_REV0)
    EDITION(GEOIP_ORG_EDITION)
    EDITION(GEOIP_ISP_EDITION)
    EDITION(GEOIP_CITY_EDITION_REV1)
    EDITION(GEOIP_REGION_EDITION_REV1)
    EDITION(GEOIP_PROXY_EDITION)
    EDITION(GEOIP_ASNUM_EDITION)
    EDITION(GEOIP_NETSPEED_EDITION)
    EDITION(GEOIP_DOMAIN_EDITION)
    EDITION(GEOIP_COUNTRY_EDITION_V6)
    EDITION(GEOIP_LOCATIONA_EDITION)
    EDITION(GEOIP_ACCURACYRADIUS_EDITION)
    EDITION(GEOIP_CITYCONFIDENCE_EDITION)
    EDITION(GEOIP_CITYCONFIDENCEDIST_EDITION)
    EDITION(GEOIP_LARGE_COUNTRY_EDITION)
    EDITION(GEOIP_LARGE_COUNTRY_EDITION_V6)
    EDITION(GEOIP_CITYCONFIDENCEDIST_ISP_ORG_EDITION)
    EDITION(GEOIP_CCM_COUNTRY_EDITION)
    EDITION(GEOIP_ASNUM_EDITION_V6)
    EDITION(GEOIP_ISP_EDITION_V6)
    EDITION(GEOIP_ORG_EDITION_V6)
    EDITION(GEOIP_DOMAIN_EDITION_V6)
    EDITION(GEOIP_LOCATIONA_EDITION_V6)
    EDITION(GEOIP_REGISTRAR_EDITION)
    EDITION(GEOIP_REGISTRAR_EDITION_V6)
    EDITION(GEOIP_USERTYPE_EDITION)
    EDITION(GEOIP_USERTYPE_EDITION_V6)
    EDITION(GEOIP_CITY_EDITION_REV1_V6)
    EDITION(GEOIP_CITY_EDITION_REV0_V6)
    EDITION(GEOIP_NETSPEED_EDITION_REV1)
    EDITION(GEOIP_NETSPEED_EDITION_REV1_V6)
    EDITION(GEOIP_COUNTRYCONF_EDITION)
    EDITION(GEOIP_CITYCONF_EDITION)
    EDITION(GEOIP_REGIONCONF_EDITION)
    EDITION(GEOIP_POSTALCONF_EDITION)
    EDITION(GEOIP_ACCURACYRADIUS_EDITION_V6)

    return 1;
}
