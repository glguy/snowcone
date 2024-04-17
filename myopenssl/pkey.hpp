#pragma once

struct lua_State;

namespace myopenssl {

auto l_read_raw(lua_State*) -> int;
auto l_read_pem(lua_State*) -> int;
auto l_gen_pkey(lua_State*) -> int;

} // namespace myopenssl
