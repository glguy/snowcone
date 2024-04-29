#include "hsfilter.hpp"

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <hs.h>

#include <exception>
#include <optional>

namespace
{
  auto push_platform(lua_State * const L, hs_platform_info const& platform) -> void
  {
    lua_createtable(L, 0, 2);
    lua_pushinteger(L, platform.cpu_features);
    lua_setfield(L, -2, "cpu_features");
    lua_pushinteger(L, platform.tune);
    lua_setfield(L, -2, "tune");
  }

  auto get_platform(lua_State *const L, int const idx) -> hs_platform_info
  {
    hs_platform_info platform{};
    lua_getfield(L, idx, "cpu_features");
    platform.cpu_features = lua_tointeger(L, -1);
    lua_getfield(L, idx, "tune");
    platform.tune = lua_tointeger(L, -1);
    lua_pop(L, 2);
    return platform;
  }

  auto compile(
      lua_State *const L,
      char const *const *const exprs,
      unsigned const *const flags,
      unsigned const *const ids,
      unsigned const N,
      hs_platform_info_t const *const platform) -> void
  {
    hs_database_t *db;
    hs_compile_error_t *error;
    auto const compile_result = hs_compile_multi(exprs, flags, ids, N, HS_MODE_BLOCK, platform, &db, &error);
    switch (compile_result)
    {
    case HS_SUCCESS:
      // db allocated
      break;
    case HS_COMPILER_ERROR:
      // error allocated
      lua_pushfstring(L, "error in regular expression %d: %s", error->expression, error->message);
      if (HS_SUCCESS != hs_free_compile_error(error))
      {
        std::terminate();
      }
      lua_error(L);
    default:
      luaL_error(L, "hs_compile_multi(%d)", int{compile_result});
    }

    char *serialize_bytes;
    size_t serialize_len;
    auto const serialize_result = hs_serialize_database(db, &serialize_bytes, &serialize_len);

    if (HS_SUCCESS != hs_free_database(db))
    {
      std::terminate();
    }

    if (HS_SUCCESS != serialize_result)
    {
      luaL_error(L, "hs_serialize_database(%d)", int{serialize_result});
    }

    lua_pushlstring(L, serialize_bytes, serialize_len);
    free(serialize_bytes);
  }

  template <typename T>
  auto calloc_with_lua(lua_State *const L, size_t N) -> T *
  {
    return static_cast<T *>(lua_newuserdatauv(L, sizeof(T) * N, 0));
  }

  auto l_serialize_regexp_db(lua_State *const L) -> int
  {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TTABLE);
    luaL_checktype(L, 3, LUA_TTABLE);
    auto const platform = lua_isnoneornil(L, 4) ? std::optional<hs_platform_info>{} : std::optional{get_platform(L, 4)};
    lua_settop(L, 3);

    auto const N = luaL_len(L, 1);

    // We use Lua to allocate these, instead of alloca or std::vector,
    // because this code can call lua_error
    auto const exprs = calloc_with_lua<char const *>(L, N);
    auto const flags = calloc_with_lua<unsigned>(L, N);
    auto const ids = calloc_with_lua<unsigned>(L, N);

    for (lua_Integer i = 1; i <= N; i++)
    {
      if (LUA_TSTRING != lua_rawgeti(L, 1, i))
      {
        luaL_error(L, "exprs[%d] not a string", i);
      }
      exprs[i - 1] = lua_tostring(L, -1);

      if (LUA_TNUMBER != lua_rawgeti(L, 2, i))
      {
        luaL_error(L, "flags[%d] not a number", i);
      }
      flags[i - 1] = lua_tonumber(L, -1);

      if (LUA_TNUMBER != lua_rawgeti(L, 3, i))
      {
        luaL_error(L, "ids[%d] not a number", i);
      }
      ids[i - 1] = lua_tonumber(L, -1);

      lua_pop(L, 3); // drops the expr, flag, id
    }

    compile(L, exprs, flags, ids, N, platform ? &*platform : nullptr);
    return 1;
  }

  auto l_get_current_platform(lua_State *const L) -> int
  {
    hs_platform_info platform;
    auto const e = hs_populate_platform(&platform);
    if (HS_SUCCESS != e)
    {
      luaL_error(L, "hs_populate_platform(%d)", int{e});
      return 0;
    }

    push_platform(L, platform);
    return 1;
  }

  luaL_Reg const M[]{
      {"serialize_regexp_db", l_serialize_regexp_db},
      {"get_current_platform", l_get_current_platform},
      {},
  };

} // namespace

auto luaopen_hsfilter(lua_State *const L) -> int
{
  luaL_newlib(L, M);

#define FLAG(flag)          \
  lua_pushinteger(L, flag); \
  lua_setfield(L, -2, #flag);

  lua_createtable(L, 0, 11);
  FLAG(HS_FLAG_ALLOWEMPTY);
  FLAG(HS_FLAG_CASELESS);
  FLAG(HS_FLAG_COMBINATION);
  FLAG(HS_FLAG_DOTALL);
  FLAG(HS_FLAG_MULTILINE);
  FLAG(HS_FLAG_PREFILTER);
  FLAG(HS_FLAG_QUIET);
  FLAG(HS_FLAG_SINGLEMATCH);
  FLAG(HS_FLAG_SOM_LEFTMOST);
  FLAG(HS_FLAG_UCP);
  FLAG(HS_FLAG_UTF8);
  lua_setfield(L, -2, "flags");

  lua_createtable(L, 0, 3);
  FLAG(HS_CPU_FEATURES_AVX2);
  FLAG(HS_CPU_FEATURES_AVX512);
  FLAG(HS_CPU_FEATURES_AVX512VBMI);
  lua_setfield(L, -2, "cpu_features");

  lua_createtable(L, 0, 11);
  FLAG(HS_TUNE_FAMILY_BDW);
  FLAG(HS_TUNE_FAMILY_GENERIC);
  FLAG(HS_TUNE_FAMILY_GLM);
  FLAG(HS_TUNE_FAMILY_HSW);
  FLAG(HS_TUNE_FAMILY_ICL);
  FLAG(HS_TUNE_FAMILY_ICX);
  FLAG(HS_TUNE_FAMILY_IVB);
  FLAG(HS_TUNE_FAMILY_SKL);
  FLAG(HS_TUNE_FAMILY_SKX);
  FLAG(HS_TUNE_FAMILY_SLM);
  FLAG(HS_TUNE_FAMILY_SNB);
  lua_setfield(L, -2, "tune");
#undef FLAG

  lua_createtable(L, 0, 3);
  lua_pushinteger(L, 1 << 0);
  lua_setfield(L, -2, "DROP");
  lua_pushinteger(L, 1 << 1);
  lua_setfield(L, -2, "KILL");
  lua_pushinteger(L, 1 << 2);
  lua_setfield(L, -2, "ALARM");
  lua_setfield(L, -2, "actions");

  return 1;
}
