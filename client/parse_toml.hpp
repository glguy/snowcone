#pragma once

struct lua_State;

auto l_parse_toml(lua_State* const L) -> int;
