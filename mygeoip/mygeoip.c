#include "mygeoip.h"

#include <GeoIP.h>

#include <lauxlib.h>
#include <lua.h>

static char const* db_type_name = "GeoIP*";

static int close_org_db(lua_State* L)
{
    GeoIP** geoip = luaL_checkudata(L, 1, db_type_name);
    GeoIP_delete(*geoip);
    *geoip = NULL;
    return 0;
}

static int open_db(lua_State* L)
{
    int type = luaL_checknumber(L, 1);
    GeoIP* geoip = GeoIP_open_type(type, GEOIP_SILENCE);
    if (NULL == geoip)
        luaL_error(L, "Failed to open");

    GeoIP** ptr = lua_newuserdata(L, sizeof geoip);
    *ptr = geoip;
    luaL_setmetatable(L, db_type_name);
    return 1;
}

static int get_name_by_addr(lua_State* L)
{
    GeoIP** geoip = luaL_checkudata(L, 1, db_type_name);
    char const* addr = luaL_checkstring(L, 2);
    GeoIPLookup gl = {0};
    char* org = GeoIP_name_by_addr_gl(*geoip, addr, &gl);
    lua_pushstring(L, org);
    free(org);
    return 1;
}

static int get_name_by_addr_v6(lua_State* L)
{
    GeoIP** geoip = luaL_checkudata(L, 1, db_type_name);
    char const* addr = luaL_checkstring(L, 2);
    GeoIPLookup gl = {0};
    char* org = GeoIP_name_by_addr_v6_gl(*geoip, addr, &gl);
    lua_pushstring(L, org);
    free(org);
    return 1;
}

static luaL_Reg M[] = {
    {"open_db", open_db},
    {0},
};

static luaL_Reg DbM[] = {
    {"get_name_by_addr", get_name_by_addr},
    {"get_name_by_addr_v6", get_name_by_addr_v6},
    {0},
};

#define EDITION__STR(_s) #_s
#define EDITION_STR(_s) EDITION__STR(_s)
#define EDITION(x)         \
    lua_pushinteger(L, x); \
    lua_setfield(L, -2, EDITION__STR(x));

int luaopen_mygeoip(lua_State* L)
{
    if (luaL_newmetatable(L, db_type_name))
    {
        lua_pushcfunction(L, close_org_db);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, close_org_db);
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
