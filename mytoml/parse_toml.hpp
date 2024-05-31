#pragma once

struct lua_State;

namespace mytoml {
auto l_parse_toml(lua_State*) -> int;
}
