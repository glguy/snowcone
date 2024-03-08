#pragma once

struct lua_State;

namespace myopenssl {

auto l_get_digest(lua_State * L) -> int;

} // namespace myopenssl
