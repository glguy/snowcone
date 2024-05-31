#pragma once

struct lua_State;

namespace mytoml {
auto l_to_toml(lua_State*) -> int;
}
