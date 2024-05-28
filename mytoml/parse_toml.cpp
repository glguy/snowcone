#include "parse_toml.hpp"
#include "toml.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

namespace {

auto push_toml_node(lua_State* const L, toml::node const& node) -> void;

auto push_toml(lua_State* const L, toml::value<std::int64_t> const& value) -> void
{
    lua_pushinteger(L, *value);
}

auto push_toml(lua_State* const L, toml::value<std::string> const& value) -> void
{
    lua_pushlstring(L, value->data(), value->size());
}

auto push_toml(lua_State* const L, toml::value<bool> const& value) -> void
{
    lua_pushboolean(L, value.get());
}

auto push_toml(lua_State* const L, toml::value<double> const& value) -> void
{
    lua_pushnumber(L, value.get());
}

auto push_toml(lua_State* const L, toml::value<toml::date> const& value) -> void
{
    throw std::runtime_error{"toml date not supported"};
}

auto push_toml(lua_State* const L, toml::value<toml::date_time> const& value) -> void
{
    throw std::runtime_error{"toml datetime not supported"};
}

auto push_toml(lua_State* const L, toml::value<toml::time> const& value) -> void
{
    throw std::runtime_error{"toml time not supported"};
}

auto push_toml(lua_State* const L, toml::table const& table) -> void
{
    lua_createtable(L, 0, table.size());
    for (auto& [k, v] : table)
    {
        lua_pushlstring(L, k.data(), k.length());
        push_toml_node(L, v);
        lua_settable(L, -3);
    }
}

auto push_toml(lua_State* const L, toml::array const& array) -> void
{
    lua_createtable(L, array.size(), 0);
    lua_Integer i = 1;
    for (auto& x : array)
    {
        push_toml_node(L, x);
        lua_rawseti(L, -2, i++);
    }
}

auto push_toml_node(lua_State* const L, toml::node const& node) -> void
{
    node.visit([L](auto&& n) { push_toml(L, n); });
}

} // namespace

auto mytoml::l_parse_toml(lua_State* const L) -> int
{
    std::size_t len;
    auto const src = luaL_checklstring(L, 1, &len);
    try
    {
        push_toml(L, toml::parse(std::string_view{src, len}));
        return 1;
    }
    catch (std::runtime_error const& err)
    {
        luaL_pushfail(L);
        lua_pushstring(L, err.what());
        return 2;
    }
}
