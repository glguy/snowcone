#pragma once

#include <openssl/bn.h>

struct lua_State;

namespace myopenssl {
auto push_bignum(lua_State*) -> BIGNUM*&;
auto l_bignum(lua_State*) -> int;
}
