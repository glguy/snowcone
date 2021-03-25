#include <GeoIP.h>

#include "lauxlib.h"

#include "lua.h"
#include "mygeoip.h"

static char const* db_type_name = "geoip db";

static int close_org_db(lua_State *L)
{
        GeoIP **geoip = luaL_checkudata(L, 1, db_type_name);
        GeoIP_delete(*geoip);
        return 0;
}

static int open_db(lua_State *L)
{
        int type = luaL_checknumber(L, 1);
        GeoIP *geoip = GeoIP_open_type(type, 0);
        if (NULL==geoip) luaL_error(L, "Failed to open");

        GeoIP **ptr = lua_newuserdata(L, sizeof geoip);
        luaL_setmetatable(L, db_type_name);
        *ptr = geoip;
        return 1;
}

static int get_name_by_addr(lua_State *L)
{
        GeoIP **geoip = luaL_checkudata(L, 1, db_type_name);
        char const* addr = luaL_checkstring(L, 2);
        GeoIPLookup gl = {};
        char *org = GeoIP_name_by_addr_gl(*geoip, addr, &gl);
        lua_pushstring(L, org);
        free(org);
        return 1;
}

static int get_name_by_addr_v6(lua_State *L)
{
        GeoIP **geoip = luaL_checkudata(L, 1, db_type_name);
        char const* addr = luaL_checkstring(L, 2);
        GeoIPLookup gl = {};
        char *org = GeoIP_name_by_addr_v6_gl(*geoip, addr, &gl);
        lua_pushstring(L, org);
        free(org);
        return 1;
}

static luaL_Reg M[] =
  {
          {"open_db", open_db},
          {},
  };

static luaL_Reg DbM[] =
  {
          {"get_name_by_addr", get_name_by_addr},
          {"get_name_by_addr_v6", get_name_by_addr_v6},
          {},
  };

int luaopen_mygeoip(lua_State *L)
{
        if (luaL_newmetatable(L, db_type_name))
        {
                lua_pushcfunction(L, close_org_db);
                lua_setfield(L, -2, "__gc");

                luaL_newlib(L, DbM);
                lua_setfield(L, -2, "__index");
        }
        lua_pop(L, 1);

        luaL_newlib(L, M);

        lua_pushinteger(L, GEOIP_ASNUM_EDITION);
        lua_setfield(L, -2, "GEOIP_ASNUM_EDITION");

        lua_pushinteger(L, GEOIP_ASNUM_EDITION_V6);
        lua_setfield(L, -2, "GEOIP_ASNUM_EDITION_V6");

        return 1;
}