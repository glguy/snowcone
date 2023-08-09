#include "hsfilter.hpp"

#ifdef LIBHS_FOUND

#include <mybase64.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <hs.h>

#include <memory>
#include <vector>

namespace
{
  unsigned int const default_flags = HS_FLAG_SINGLEMATCH;

  auto irc_commands(lua_State *const L, char const *const bytes, std::size_t const len) -> void
  {
    auto const chunk = std::size_t{300};
    char buffer[mybase64::encoded_size(chunk) + 1];

    // randomized session check value common across all commands
    auto const check = rand();

    lua_createtable(L, (len + chunk - 1) / chunk + 2, 0);
    lua_Integer o = 1;

    lua_pushfstring(L, "SETFILTER * %d NEW", check);
    lua_seti(L, -2, o++);

    for (size_t i = 0; i < len; i += chunk)
    {
      auto const remain = len - i;
      mybase64::encode({&bytes[i], remain < chunk ? remain : chunk}, buffer);
      lua_pushfstring(L, "SETFILTER * %d +%s", check, buffer);
      lua_seti(L, -2, o++);
    }

    lua_pushfstring(L, "SETFILTER * %d APPLY", check);
    lua_seti(L, -2, o++);
  }

  struct Inputs
  {
    std::vector<char const *> expressions;
    std::vector<unsigned> flags;
    std::vector<unsigned> ids;
  };

  auto compile(lua_State *const L, Inputs const &inputs) -> std::pair<char *, std::size_t>
  {
    hs_database_t *db;
    hs_compile_error_t *error;
    hs_platform_info_t const *const platform = nullptr;

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
      luaL_error(L, "hs_serialize_database(%d)", int{e});
    }

    return {serialize_bytes, serialize_len};
  }

  auto compile_regexp_db_to_irc(lua_State *const L) -> int
  {
    Inputs inputs;

    lua_settop(L, 1);
    auto const N = luaL_len(L, 1);

    for (size_t i = 1; i <= N; i++)
    {
      lua_geti(L, 1, i);

      lua_getfield(L, -1, "flags");
      auto const flag = lua_tointeger(L, -1);
      inputs.flags.push_back(flag);

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

    auto const [serialize_bytes, serialize_len] = compile(L, inputs);
    lua_settop(L, 0); // toss the strings
    irc_commands(L, serialize_bytes, serialize_len);
    free(serialize_bytes);
    return 1;
  }

  luaL_Reg const M[]{
      {"compile_regexp_db_to_irc", compile_regexp_db_to_irc},
      {nullptr, nullptr},
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
#undef FLAG

  lua_pushinteger(L, 1 << 0);
  lua_setfield(L, -2, "DROP");
  lua_pushinteger(L, 1 << 1);
  lua_setfield(L, -2, "KILL");
  lua_pushinteger(L, 1 << 2);
  lua_setfield(L, -2, "ALARM");

  return 1;
}

#endif