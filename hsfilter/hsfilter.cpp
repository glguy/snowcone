#include "hsfilter.hpp"

#include <mybase64.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <hs.h>

#include <vector>

namespace
{
  auto get_platform(lua_State *L, int idx) -> hs_platform_info;

  unsigned int const default_flags = HS_FLAG_SINGLEMATCH;

  struct Inputs
  {
    std::vector<char const *> expressions;
    std::vector<unsigned> flags;
    std::vector<unsigned> ids;
  };

  auto compile(lua_State *const L, Inputs const &inputs, hs_platform_info_t *const platform) -> std::pair<char *, std::size_t>
  {
    hs_database_t *db;
    hs_compile_error_t *error;
    auto const compile_result = hs_compile_multi(inputs.expressions.data(), inputs.flags.data(), inputs.ids.data(), inputs.expressions.size(), HS_MODE_BLOCK, platform, &db, &error);
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

    return {serialize_bytes, serialize_len};
  }

  auto l_serialize_regexp_db(lua_State *const L) -> int
  {
    Inputs inputs;

    lua_settop(L, 2);

    hs_platform_info platform;
    auto const has_platform = !lua_isnoneornil(L, 2);
    if (has_platform)
    {
      platform = get_platform(L, 2);
    }

    auto const N = luaL_len(L, 1);

    for (size_t i = 1; i <= N; i++)
    {
      lua_geti(L, 1, i);

      lua_getfield(L, -1, "flags");
      int is_num;
      auto const flag = lua_tointegerx(L, -1, &is_num);
      inputs.flags.push_back(is_num ? flag : default_flags);

      lua_getfield(L, -2, "id");
      auto const id = lua_tointeger(L, -1);
      inputs.ids.push_back(id);

      lua_pop(L, 2); // drops the flag and id

      lua_getfield(L, -1, "regexp");
      auto const str = lua_tostring(L, -1);

      lua_remove(L, -2); // remove the table leaving the string

      if (nullptr == str)
      {
        luaL_error(L, "regexp not a string");
        return 0;
      }

      inputs.expressions.push_back(str);
    }

    auto const [serialize_bytes, serialize_len] = compile(L, inputs, has_platform ? &platform : nullptr);
    lua_settop(L, 0); // toss the strings
    lua_pushlstring(L, serialize_bytes, serialize_len);
    free(serialize_bytes);
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

    lua_createtable(L, 0, 2);
    lua_pushinteger(L, platform.cpu_features);
    lua_setfield(L, -2, "cpu_features");

    lua_pushinteger(L, platform.tune);
    lua_setfield(L, -2, "tune");

    return 1;
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

  FLAG(HS_CPU_FEATURES_AVX2);
  FLAG(HS_CPU_FEATURES_AVX512);
  FLAG(HS_CPU_FEATURES_AVX512VBMI);

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
#undef FLAG

  lua_pushinteger(L, 1 << 0);
  lua_setfield(L, -2, "DROP");
  lua_pushinteger(L, 1 << 1);
  lua_setfield(L, -2, "KILL");
  lua_pushinteger(L, 1 << 2);
  lua_setfield(L, -2, "ALARM");

  return 1;
}
