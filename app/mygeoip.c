#include <GeoIP.h>

#include "lauxlib.h"

#include "mygeoip.h"

static int close_org_db(lua_State *L)
{
        GeoIP **geoip = luaL_checkudata(L, 1, "geoip org db");
        GeoIP_delete(*geoip);
        return 0;
}

static int open_org_db(lua_State *L)
{
        GeoIP *geoip = GeoIP_open_type(GEOIP_ASNUM_EDITION, 0);
        if (NULL==geoip) luaL_error(L, "Failed to open GeoIPOrg.dat");

        GeoIP **ptr = lua_newuserdata(L, sizeof geoip);
        luaL_setmetatable(L, "geoip org db");
        *ptr = geoip;
        return 1;
}

static int get_org_by_addr(lua_State *L)
{
        GeoIP **geoip = luaL_checkudata(L, 1, "geoip org db");
        char const* addr = luaL_checkstring(L, 2);
        GeoIPLookup gl = {};
        char *org = GeoIP_name_by_addr_gl(*geoip, addr, &gl);
        lua_pushstring(L, org);
        free(org);
        return 1;
}

static luaL_Reg M[] =
  {
          {"open_org_db", open_org_db},
          {},
  };

static luaL_Reg OrgM[] =
  {
          {"get_org_by_addr", get_org_by_addr},
          {},
  };

int luaopen_mygeoip(lua_State *L)
{
        if (luaL_newmetatable(L, "geoip org db"))
        {
                lua_pushcfunction(L, close_org_db);
                lua_setfield(L, -2, "__gc");

                luaL_newlib(L, OrgM);
                lua_setfield(L, -2, "__index");
        }
        lua_pop(L, 1);

        luaL_newlib(L, M);
        return 1;
}