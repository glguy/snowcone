#pragma once

struct lua_State;

#include <openssl/evp.h>

namespace myopenssl {

auto l_get_digest(lua_State* L) -> int;
auto check_digest(lua_State* L, int arg) -> EVP_MD const*;

} // namespace myopenssl
